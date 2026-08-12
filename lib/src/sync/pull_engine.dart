import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../api/exceptions.dart';
import '../concurrency/concurrency_pool.dart';
import '../utils/sdk_log.dart';
import '../concurrency/write_queue.dart';
import '../database/daos/doctype_meta_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../models/closure_result.dart';
import '../models/dep_graph.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';
import 'cursor.dart';
import 'pull_apply.dart';
import 'pull_page_fetcher.dart';
import 'sync_state.dart';
import 'sync_state_notifier.dart';

/// Back-compat alias. Use [MetaResolverFn] directly in new code.
typedef MetaResolver = MetaResolverFn;

/// Per-doctype schema reconcile hook. Called at the start of each
/// `_runDoctype` with the meta the engine is about to apply, so the
/// receiver can `ALTER TABLE ADD COLUMN` any fields that were added to
/// meta after the table was originally created.
///
/// In production this is wired to
/// `OfflineRepository.reconcileParentTableForMeta`. Optional — when
/// null, no reconcile happens and writes assume schema parity (fine for
/// tests).
typedef SchemaReconcilerFn =
    Future<void> Function(String doctype, String tableName, DocTypeMeta meta);

/// Drives the pull side of the sync engine. Spec §5.1 + §5.4.
///
/// For each (non-child) doctype in the closure:
/// 1. Probe `OutboxDao.hasActivePushFor(doctype)` — defer if push is active
///    for this doctype to avoid pulling stale server state over local
///    edits in flight.
/// 2. Resolve parent + child metas.
/// 3. Loop pages via [PullPageFetcher]. Each page → [PullApply.applyPage]
///    in a transaction, then the advanced cursor (complete:false) is
///    checkpointed via [DoctypeMetaDao.setLastOkCursor] (#64). When the
///    doctype drains, the cursor is flipped to complete:true.
/// 4. A relaunch mid initial-sync resumes from the last checkpointed page
///    (limit_start = cursor.start) instead of page 0.
///
/// Doctypes drain in parallel through [pool] (typically PullPool, sized by
/// [DeviceTier]).
class PullEngine {
  final Database db;
  final DoctypeMetaDao metaDao;
  final OutboxDao outboxDao;
  final ConcurrencyPool pool;
  final PullPageFetcher fetcher;
  final int pageSize;
  final SyncStateNotifier notifier;
  final MetaResolver metaResolver;

  /// Optional. When provided, every page apply is routed through the
  /// [WriteQueue] for that doctype — providing per-doctype serialisation
  /// across pull and push activity and batched fsyncs across consecutive
  /// pages. When null, each page opens its own `db.transaction(...)`
  /// directly (simpler, fine for tests and small datasets).
  final WriteQueueResolver? writeQueueResolver;

  /// Lazy cache of per-doctype WriteQueue instances. Created on first use
  /// when [writeQueueResolver] is non-null.
  final Map<String, WriteQueue> _writeQueues = {};

  /// Optional schema-reconcile callback invoked at the start of each
  /// `_runDoctype`. See [SchemaReconcilerFn] for rationale. Failure is
  /// caught and logged — pull continues with whatever columns currently
  /// exist on the table.
  final SchemaReconcilerFn? schemaReconciler;

  PullEngine({
    required this.db,
    required this.metaDao,
    required this.outboxDao,
    required this.pool,
    required this.fetcher,
    required this.pageSize,
    required this.notifier,
    required this.metaResolver,
    this.writeQueueResolver,
    this.schemaReconciler,
  });

  /// Returns the set of doctypes that were deferred (skipped because a
  /// push was active for them). Caller (SyncController) is expected to
  /// re-run [run] for this subset after the push engine completes — see
  /// SIG-2.
  /// [allowedDoctypes] — when non-null, only doctypes in the set are pulled.
  /// Used by the SDK to exclude permission-denied doctypes without mutating
  /// the closure graph.
  Future<Set<String>> run(
    ClosureResult closure, {
    Set<String>? allowedDoctypes,
  }) async {
    notifier.value = notifier.value.copyWith(isPulling: true);
    final deferred = <String>{};
    try {
      final futures = <Future<void>>[];
      for (final dt in closure.doctypes) {
        if (closure.childDoctypes.contains(dt)) continue;
        if (allowedDoctypes != null && !allowedDoctypes.contains(dt)) continue;
        futures.add(
          pool.submit<void>(() => _runDoctype(dt, closure, deferred)),
        );
      }
      await Future.wait(futures);
      return deferred;
    } finally {
      // Always reset `isPulling` and stamp `lastSyncAt` — without this,
      // an unhandled error in any worker (or the closure walk itself)
      // would leave the notifier showing "syncing…" forever.
      notifier.value = notifier.value.copyWith(
        isPulling: false,
        lastSyncAt: DateTime.now().toUtc(),
      );
    }
  }

  Future<void> _runDoctype(
    String doctype,
    ClosureResult closure,
    Set<String> deferred,
  ) async {
    if (await outboxDao.hasActivePushFor(doctype)) {
      // Dart's main isolate is single-threaded so add() on a shared Set
      // across parallel `pool.submit` futures is safe in practice. If the
      // pool ever moves work off-isolate, switch to gathering deferred
      // doctypes from the futures' return values.
      deferred.add(doctype);
      notifier.value = notifier.value.updatePerDoctype(
        doctype,
        const DoctypeSyncState(
          deferred: true,
          note: 'deferred: active push for this doctype',
        ),
      );
      return;
    }

    final DocTypeMeta meta;
    try {
      meta = await metaResolver(doctype);
    } catch (e, st) {
      // A doctype whose meta can't be resolved — e.g. a server 500 from a
      // doctype missing its controller module, or a permission failure — must
      // be SKIPPED, never abort the whole closure pull. Without this the throw
      // escapes _runDoctype, the pool task fails, Future.wait rethrows and
      // run() aborts, stranding every OTHER doctype ("core data did not
      // download"; retry re-hits the same failure and stalls).
      sdkLog(
        'PullEngine._runDoctype($doctype): meta resolve failed, skipping — $e\n$st',
      );
      // Two separate jobs here, and both are needed:
      //
      //  1. REPORT it on the release-visible, host-observable channel
      //     (SyncState.failedMetaSyncs) — the debug-only sdkLog above compiles
      //     out in release and the per-doctype `note` is read by no progress UI.
      //  2. STOP RE-REQUESTING it when the refusal is terminal (403 / 5xx), by
      //     demoting the doctype out of the mobile-form set. Reporting alone
      //     leaves the doctype in the closure, so it is re-requested and
      //     re-refused on every single sweep, forever.
      //
      // A terminal failure gets the specific reason; anything transient keeps
      // the generic one and stays in the set so the next sweep retries it.
      if (_isTerminalPullFailure(e) &&
          await metaDao.demoteFromMobileForm(doctype)) {
        notifier.recordMetaSyncFailure(doctype, _terminalSkipReason(e));
        sdkLog(
          'PullEngine._runDoctype($doctype): demoted from mobile-form set '
          '(terminal meta failure).',
        );
      } else {
        notifier.recordMetaSyncFailure(doctype, 'meta: $e');
      }
      notifier.value = notifier.value.updatePerDoctype(
        doctype,
        // deferred:true so the progress screen (which reads deferred +
        // completedAt only) shows this as deferred, not perpetually
        // in-progress.
        DoctypeSyncState(deferred: true, note: 'failed (meta): $e'),
      );
      return;
    }

    // Reconcile the on-disk schema against THIS meta snapshot before
    // applying any pages. Closes the SNF/SDK race where the table was
    // created from a slightly older meta and PullApply now wants to
    // UPDATE columns that don't exist yet. See [SchemaReconcilerFn].
    final reconciler = schemaReconciler;
    if (reconciler != null) {
      try {
        final parentTableForReconcile = await metaDao.tableNameFor(doctype);
        await reconciler(doctype, parentTableForReconcile, meta);
      } catch (e, st) {
        sdkLog(
          'PullEngine._runDoctype($doctype): schemaReconciler failed — $e\n$st',
        );
      }
    }

    var scratch = Cursor.fromJson(
      _decodeJsonOrNull(await metaDao.getLastOkCursor(doctype)),
    );
    final startedAt = DateTime.now().toUtc();
    var pulledCount = 0;
    int? lastPageSize;
    final bool isInitialSync = !scratch.complete;

    notifier.value = notifier.value.updatePerDoctype(
      doctype,
      DoctypeSyncState(startedAt: startedAt),
    );

    final parentTable = await metaDao.tableNameFor(doctype);

    // Resolve child metas for every Table / Table MultiSelect outgoing edge.
    final childInfo = <String, PullApplyChildInfo>{};
    final graph = closure.graph[doctype];
    if (graph != null) {
      for (final edge in graph.outgoing.where(
        (e) => e.kind == DepEdgeKind.child,
      )) {
        final DocTypeMeta childMeta;
        try {
          childMeta = await metaResolver(edge.targetDoctype);
        } catch (e, st) {
          // Can't apply a parent's pages without its child schema — skip the
          // parent doctype rather than aborting the entire pull.
          sdkLog(
            'PullEngine._runDoctype($doctype): child meta '
            '${edge.targetDoctype} resolve failed, skipping — $e\n$st',
          );
          // NOTE — a `demoteFromMobileForm(doctype)` on this path was
          // considered and REJECTED. Demoting the PARENT because one of its
          // child tables failed to resolve removes a form the user can still
          // use, and contradicts the skip-only-this-edge reasoning below.
          // Demoting the CHILD would be a no-op anyway: `demoteFromMobileForm`
          // only clears rows with `isMobileForm = 1`, and a child table
          // (`istable`) is never a mobile form. So this path reports and
          // continues; it does not demote.
          //
          // Record the CHILD doctype's failure observably, then SKIP ONLY this
          // child edge (continue) rather than aborting the whole parent
          // (return): the parent's own scalar fields and its other child
          // tables still pull. Dropping the entire parent for one broken child
          // table silently zeroes what may be an entry-point form doctype.
          //
          // CONSEQUENCE — the skipped field's rows go STALE, they are NOT
          // deleted. `edge.field` is simply never added to `childInfo`, and
          // both of PullApply's apply paths iterate ONLY
          // `childMetasByFieldname.entries`; each child wipe is keyed
          // `parent_uuid = ? AND parentfield = ?`, so a fieldname absent from
          // that map is never queried and never deleted. Whatever was cached
          // for this child field on an earlier successful pull is therefore
          // left in place unchanged — data-safe (no silent data loss), but the
          // rows may be out of date until the child meta resolves again.
          //
          // Note the failure is attributed to the CHILD doctype below (the
          // thing that actually failed to resolve), NOT to the parent, so the
          // parent's own per-doctype sync state still reports success.
          notifier.recordMetaSyncFailure(
            edge.targetDoctype,
            'child meta (parent $doctype): $e',
          );
          continue;
        }
        childInfo[edge.field] = PullApplyChildInfo(
          edge.targetDoctype,
          childMeta,
        );
      }
    }

    try {
      while (true) {
        final result = await fetcher.fetch(
          doctype: doctype,
          meta: meta,
          cursor: scratch,
          pageSize: pageSize,
        );
        if (result.rows.isEmpty) {
          // An empty page is normally end-of-stream. The exception is a page
          // whose names were ALL dropped by the server's per-doc permission
          // gate: treating that as drained falls through to markComplete()
          // below and records the doctype as fully pulled with every later
          // page unfetched — silent, permanent loss recoverable only by
          // clearing the cursor. Skip past it instead.
          //
          // Both modes can skip. Initial mode steps `limit_start` past the
          // scanned window; incremental mode (where `limit_start` is pinned at
          // 0) advances `modified` to the scanned window's high-water mark.
          // `pageFiltered` is the fetcher's promise that `advancedCursor`
          // really moved, so this cannot re-request the same window.
          if (!result.pageFiltered) break;
          scratch = result.advancedCursor;
          // Checkpoint the skip so a failure on a LATER page does not discard
          // it and re-scan the whole denied block next cycle. Safe mid-loop: in
          // incremental mode the on-disk cursor is already `complete: true` and
          // this only moves it forward past a window that yielded zero
          // applicable docs; in initial mode this is the same `complete: false`
          // checkpoint the applied-page path writes below (and `toJson()`
          // returns null — no write — for a still-watermarkless first page).
          final skipCursorJson = scratch.toJson();
          if (skipCursorJson != null) {
            await metaDao.setLastOkCursor(doctype, jsonEncode(skipCursorJson));
          }
          continue;
        }

        if (writeQueueResolver != null) {
          final wq = _writeQueues.putIfAbsent(
            doctype,
            () => writeQueueResolver!(doctype),
          );
          await wq.submit<void>((txn) async {
            await PullApply.applyPageInTxn(
              txn: txn,
              parentMeta: meta,
              parentTable: parentTable,
              childMetasByFieldname: childInfo,
              rows: result.rows,
              isInitialSync: isInitialSync,
            );
          });
        } else {
          await PullApply.applyPage(
            db: db,
            parentMeta: meta,
            parentTable: parentTable,
            childMetasByFieldname: childInfo,
            rows: result.rows,
            isInitialSync: isInitialSync,
          );
        }

        pulledCount += result.rows.length;
        lastPageSize = result.rows.length;
        final priorModified = scratch.modified;
        final priorName = scratch.name;
        scratch = result.advancedCursor;

        notifier.value = notifier.value.updatePerDoctype(
          doctype,
          DoctypeSyncState(
            pulledCount: pulledCount,
            lastPageSize: lastPageSize,
            hasMore: lastPageSize == pageSize,
            startedAt: startedAt,
          ),
        );

        // #64: checkpoint the cursor after every successfully-applied page so
        // an app-kill mid initial-sync resumes from here (limit_start =
        // scratch.start) instead of page 0. `scratch` is complete:false here;
        // the post-loop markComplete() flip remains the only place `complete`
        // FLIPS false→true (the filtered-skip checkpoint above re-writes a
        // cursor that is already complete, it never flips one). Mirrors
        // SyncService._pullOneInternal's per-page journal. A crash between the
        // page apply and this write re-applies the page on resume — idempotent
        // via PullApply's UPSERT.
        final pageCursorJson = scratch.toJson();
        if (pageCursorJson != null) {
          await metaDao.setLastOkCursor(doctype, jsonEncode(pageCursorJson));
        }

        // Spec §5.1: only break on empty page. A short non-empty page is
        // still followed by one confirmatory empty fetch — Frappe doesn't
        // tell us "no more rows" inline; we have to ask. The "fail before
        // confirmation" case (network error on the next request) is what
        // protects the cursor from advancing prematurely.

        // Stall guard (incremental only): when `modified >= cursor.modified`
        // returns a non-empty page where every row shares the same modified
        // timestamp, the advanced cursor equals the input cursor and the next
        // request returns the same page — infinite loop. Not applicable to
        // initial sync (complete=false) because that path uses limit_start
        // offset pagination, which always advances.
        if (scratch.complete &&
            scratch.modified == priorModified &&
            scratch.name == priorName) {
          break;
        }
      }

      // Cursor is persisted only when the doctype drains fully — partial
      // pulls leave the on-disk cursor untouched so a relaunch resumes
      // from the last fully-applied page. We flip `complete: true` here
      // (and ONLY here) so the next pull treats the doctype as
      // INCREMENTAL — same semantics as SyncService._pullOneInternal's
      // final-page complete flip. Without this, the two pull paths wrote
      // conflicting cursor formats (SIG-9): SyncService persisted with
      // `complete`, PullEngine dropped it, the next SyncService read saw
      // missing `complete` and re-fetched the entire dataset.
      final scratchComplete = scratch.markComplete();
      final cursorJson = scratchComplete.toJson();
      if (cursorJson != null) {
        await metaDao.setLastOkCursor(doctype, jsonEncode(cursorJson));
      }
      notifier.value = notifier.value.updatePerDoctype(
        doctype,
        DoctypeSyncState(
          pulledCount: pulledCount,
          lastPageSize: lastPageSize,
          hasMore: false,
          startedAt: startedAt,
          completedAt: DateTime.now().toUtc(),
          lastOkCursor: scratchComplete,
        ),
      );
      // Recovered: drop any prior "skipped (no access / server error)" note so
      // the sync-feedback surface stops reporting a doctype that now pulled.
      notifier.clearMetaSyncFailure(doctype);
    } catch (e, st) {
      // Mid-pull failure: do NOT persist cursor. Surface the doctype's
      // current progress so the UI can show partial counts; full retry
      // happens on next pull cycle.
      sdkLog('PullEngine.pull($doctype) failed mid-pull — $e\n$st');
      // A 403 is the server declining to read this doctype at all, which is an
      // EXPECTED steady state rather than a fault: the closure pull is no longer
      // gated on client-side `canRead` (reference masters can carry can_read=0
      // yet still be required for link pickers). Reported as `deferred` so a
      // host rendering per-doctype state does not show a permanent red "failed"
      // for something working as designed. Real faults (5xx, transport, schema)
      // keep the plain failed shape.
      final refused = e is FrappeException && e.statusCode == 403;
      // Reporting it is not enough. Until this doctype leaves the mobile-form
      // set it is re-requested and re-refused on EVERY sweep — the measured
      // steady state was a 403 (DocType) and a 500 (Number Card) recurring 5x
      // each in a 10-minute capture. Demote on a terminal refusal so the
      // request stops being made.
      //
      // DEMOTION IS NOT SELF-HEALING WITHIN A SESSION. Only
      // `resyncMobileConfiguration` re-promotes, and the SDK calls it at login
      // and `initialize()` — not on a sync cycle. So a demoted doctype is gone
      // from `getMobileFormDoctypeNames()` (the closure's entry-point source)
      // and from the workspace until the app is relaunched. That is why
      // [_isTerminalPullFailure] is deliberately narrow: the cost of demoting
      // a doctype that WOULD have recovered is far higher than the cost of
      // re-requesting one that will not.
      if (_isTerminalPullFailure(e) &&
          await metaDao.demoteFromMobileForm(doctype)) {
        notifier.recordMetaSyncFailure(doctype, _terminalSkipReason(e));
        sdkLog(
          'PullEngine.pull($doctype): demoted from mobile-form set '
          '(terminal data failure — read-denied or server error).',
        );
      }
      notifier.value = notifier.value.updatePerDoctype(
        doctype,
        DoctypeSyncState(
          pulledCount: pulledCount,
          lastPageSize: lastPageSize,
          startedAt: startedAt,
          deferred: refused,
          note: refused
              ? 'deferred: server refused read (403) for this doctype'
              : 'failed: $e',
        ),
      );
    }
  }

  /// Gateway / availability statuses, excluded from the terminal set even
  /// though they are 5xx.
  ///
  /// A 502/503/504 is an infrastructure hiccup IN FRONT OF the app server — it
  /// says nothing about this doctype, and the next sweep is very likely to
  /// succeed. 502 additionally covers the SDK's OWN malformed-batch guard:
  /// `DoctypeService.bulkGetWithChildren` throws `ApiException(…, 502)` when a
  /// 2xx body is not `{"message": [...]}` (a truncated or proxy-mangled
  /// response on the largest payload the SDK requests). Treating that as
  /// terminal meant ONE truncated response demoted the doctype, which is
  /// strictly worse than the data-loss bug the guard was added to prevent.
  ///
  /// The asymmetry is what settles it: a doctype left in the set costs a
  /// repeated request per sweep, and recovers by itself. A demoted doctype
  /// costs the user that form — and its sync — until the next login or
  /// `FrappeSDK.initialize`, because nothing else re-promotes it.
  static const Set<int> _transientServerStatuses = <int>{502, 503, 504};

  /// A server response the pull can never satisfy by retrying: read-denied
  /// (403) or a genuine server-side error (5xx other than the gateway family
  /// above — e.g. a 500 from a doctype missing its controller, which recurs
  /// identically on every sweep). Transient failures (network, timeout,
  /// 401-before-refresh, gateway 5xx) are excluded so a blip never demotes a
  /// form the user can still use.
  static bool _isTerminalPullFailure(Object e) {
    if (e is NetworkException) return false;
    if (e is FrappeException) {
      final s = e.statusCode;
      if (s == null) return false;
      if (_transientServerStatuses.contains(s)) return false;
      return s == 403 || s >= 500;
    }
    return false;
  }

  /// Short, user-facing reason for skipping a doctype during sync — surfaced on
  /// [SyncState.failedMetaSyncs] so the UI can tell the user WHY an item was
  /// left out (permission vs a transient server-side error) instead of failing
  /// silently.
  static String _terminalSkipReason(Object e) {
    if (e is FrappeException) {
      final s = e.statusCode;
      if (s == 403) return 'No access (permission denied)';
      // Deliberately NOT "temporarily unavailable": this string is only ever
      // produced for a status [_isTerminalPullFailure] classified as terminal,
      // and the genuinely temporary 5xx (502/503/504) no longer reach it.
      if (s != null && s >= 500) return 'Unavailable (server error)';
    }
    return 'Skipped';
  }

  static Map<String, dynamic>? _decodeJsonOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}
