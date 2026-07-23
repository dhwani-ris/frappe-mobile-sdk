import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../api/exceptions.dart';
import '../concurrency/concurrency_pool.dart';
import '../concurrency/write_queue.dart';
import '../database/daos/doctype_meta_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../database/table_name.dart';
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
///    in a transaction. Cursor is held in memory until the doctype is
///    fully drained (last page returned < pageSize rows or threw); then
///    persisted via [DoctypeMetaDao.setLastOkCursor].
/// 4. Cursor advance is per-doctype atomic — partial pulls leave the
///    persisted cursor untouched, so a relaunch resumes from the last
///    fully-applied page.
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

  /// Optional. Invoked ONCE at the end of a pull round (one [run] call)
  /// with the SET of doctypes that hard-403'd during that round. Wired by
  /// [SyncEngineBuilder] to apply the storm-breaker: if any of the denied
  /// doctypes is PROTECTED (a mobile-form entry point or one that has ever
  /// synced rows) the whole round is treated as a session-level AUTH EVENT
  /// — ZERO skips recorded, an `auth` error surfaced. Otherwise each denied
  /// doctype (all unprotected by construction) is recorded as a
  /// skip-with-expiry. Strictly counts HTTP 403 / PermissionError — never
  /// timeouts, SocketException, 5xx, or "no such table", which stay
  /// retryable. Failure inside the callback is caught and logged — it never
  /// aborts the pull.
  final Future<void> Function(Set<String> denied403)? onPermissionDeniedRound;

  /// Optional. Invoked with a doctype name after it FULLY drains with a
  /// 200 (complete-flip). Wired by [SyncEngineBuilder] to remove a stale
  /// permission-skip row so a doctype that was denied and is now readable
  /// self-heals immediately. Failure is caught and logged.
  final Future<void> Function(String doctype)? onDoctypePullOk;

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
    this.onPermissionDeniedRound,
    this.onDoctypePullOk,
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
    // Compute the effective pullable set ONCE (post child-exclusion +
    // `allowedDoctypes` filter) — this is both the work list for this round
    // and the "of N" denominator emitted on [SyncState.plannedPullDoctypes]
    // so a bootstrap progress bar has its total before any per-doctype state
    // lands. Emitted alongside `isPulling: true` in a single copyWith.
    final planned = <String>{};
    for (final dt in closure.doctypes) {
      if (closure.childDoctypes.contains(dt)) continue;
      if (allowedDoctypes != null && !allowedDoctypes.contains(dt)) continue;
      planned.add(dt);
    }
    notifier.value = notifier.value.copyWith(
      isPulling: true,
      plannedPullDoctypes: planned,
    );
    final deferred = <String>{};
    // Round-local set of doctypes that hard-403'd this pull. Populated by
    // the workers (single-isolate → shared-Set add is safe, same as
    // `deferred`) and handed to the storm-breaker exactly once after all
    // workers finish. Kept OUT of `_runDoctype`'s immediate side effects so
    // the auth-event vs individual-skip decision can see the WHOLE round.
    final denied403 = <String>{};
    try {
      final futures = <Future<void>>[];
      for (final dt in planned) {
        futures.add(
          pool.submit<void>(() => _runDoctype(dt, closure, deferred, denied403)),
        );
      }
      await Future.wait(futures);
      // Storm-breaker decision point. Fire the round callback ONCE with the
      // full denied set; the wiring decides auth-event vs skip-with-expiry.
      final roundCb = onPermissionDeniedRound;
      if (roundCb != null) {
        try {
          await roundCb(denied403);
        } catch (e, st) {
          debugPrint('PullEngine.run: onPermissionDeniedRound failed — $e\n$st');
        }
      }
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
    Set<String> denied403,
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

    final meta = await metaResolver(doctype);

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
        debugPrint(
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

    notifier.value = notifier.value.updatePerDoctype(
      doctype,
      DoctypeSyncState(startedAt: startedAt),
    );

    final parentTable =
        await metaDao.getTableName(doctype) ??
        normalizeDoctypeTableName(doctype);

    // Resolve child metas for every Table / Table MultiSelect outgoing edge.
    final childInfo = <String, PullApplyChildInfo>{};
    final graph = closure.graph[doctype];
    if (graph != null) {
      for (final edge in graph.outgoing.where(
        (e) => e.kind == DepEdgeKind.child,
      )) {
        final childMeta = await metaResolver(edge.targetDoctype);
        childInfo[edge.field] = PullApplyChildInfo(
          edge.targetDoctype,
          childMeta,
        );
      }
    }

    // The first page of an INCREMENTAL (complete=true) pull is a seam
    // refetch: it re-pulls the whole `modified == watermark` block (Phase A
    // anchored at `name > ''`) so no same-second row is missed. RESUME
    // (complete=false) and INITIAL (null cursor) pages never seam-refetch —
    // they resume strictly after the persisted `(modified, name)`.
    var firstIteration = true;

    try {
      while (true) {
        final result = await fetcher.fetch(
          doctype: doctype,
          meta: meta,
          cursor: scratch,
          pageSize: pageSize,
          seamRefetch: firstIteration && scratch.complete,
        );
        firstIteration = false;
        if (result.rows.isEmpty) break;

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
            );
          });
        } else {
          await PullApply.applyPage(
            db: db,
            parentMeta: meta,
            parentTable: parentTable,
            childMetasByFieldname: childInfo,
            rows: result.rows,
          );
        }

        pulledCount += result.rows.length;
        lastPageSize = result.rows.length;
        final priorModified = scratch.modified;
        final priorName = scratch.name;
        scratch = result.advancedCursor;

        // Per-page cursor persistence (THE fix). Journal the advancing
        // `(modified, name)` after EVERY successfully-applied page, keeping
        // `complete=false` for an in-progress pull. On `complete=false` the
        // next pull (this or the other path — SIG-9) RESUMES from this keyset
        // point instead of discarding it and restarting unfiltered at offset
        // 0. A failed page (catch block below) persists nothing extra — the
        // last durable cursor is this journal, so at most one page is lost.
        final pageCursorJson = scratch.toJson();
        if (pageCursorJson != null) {
          await metaDao.setLastOkCursor(doctype, jsonEncode(pageCursorJson));
        }

        notifier.value = notifier.value.updatePerDoctype(
          doctype,
          DoctypeSyncState(
            pulledCount: pulledCount,
            lastPageSize: lastPageSize,
            hasMore: lastPageSize == pageSize,
            startedAt: startedAt,
          ),
        );

        // Spec §5.1: only break on empty page. A short non-empty page is
        // still followed by one confirmatory (keyset) fetch — Frappe doesn't
        // tell us "no more rows" inline; we have to ask. The "fail before
        // confirmation" case (network error on the next request) is what
        // protects against advancing past unapplied rows; per-page persist
        // makes that failure cost at most one page.

        // No-advance ⟹ drained ⟹ safe to stop (debugPrint + break).
        // Under the two-phase keyset, a NON-EMPTY page whose last row does not
        // move the cursor (new anchor == previous anchor) can only mean the
        // page's last row IS the anchor — i.e. Phase A returned the anchor's
        // watermark block and Phase B (`modified > m`) came back empty, so the
        // dataset is fully drained. Breaking here can therefore NEVER truncate
        // clustered data: a same-`modified` tie block larger than pageSize
        // advances page-by-page via `name` (each page's last name > the prior
        // anchor), so the guard simply does not trip until the block AND the
        // Phase B tail are exhausted. (The truncation risk this comment used to
        // cite belonged to the OLD single-predicate `modified >=` design, where
        // no-advance could happen with rows still pending — not so under
        // keyset.) Restoring the break also removes the wasteful confirmatory
        // round-trip on the incremental seam of an unchanged doctype (the loop
        // then falls through to the markComplete() flip below).
        if (scratch.modified == priorModified && scratch.name == priorName) {
          debugPrint(
            'PullEngine._runDoctype($doctype): cursor did not advance on a '
            'non-empty page (modified=${scratch.modified}, '
            'name=${scratch.name}) — dataset drained; stopping.',
          );
          break;
        }
      }

      // Full-drain completion flip. Per-page persistence above already wrote
      // the resume cursor (complete=false); here we promote it to
      // `complete: true` (ONLY here) so the next pull treats the doctype as
      // INCREMENTAL — same semantics as SyncService._pullOneInternal's
      // final-page complete flip, and the same on-disk JSON shape so the two
      // pull paths interoperate (SIG-9).
      final scratchComplete = scratch.markComplete();
      final cursorJson = scratchComplete.toJson();
      if (cursorJson != null) {
        await metaDao.setLastOkCursor(doctype, jsonEncode(cursorJson));
      }

      // Full drain succeeded (HTTP 200 across every page) → the surveyor
      // CAN read this doctype. Clear any stale permission-skip row so a
      // previously-denied-then-granted doctype self-heals now instead of
      // waiting out the TTL. Best-effort; never aborts the pull.
      final okCb = onDoctypePullOk;
      if (okCb != null) {
        try {
          await okCb(doctype);
        } catch (okErr, okSt) {
          debugPrint(
            'PullEngine._runDoctype($doctype): onDoctypePullOk failed '
            '— $okErr\n$okSt',
          );
        }
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
    } catch (e, st) {
      // Mid-pull failure: do NOT persist cursor. Surface the doctype's
      // current progress so the UI can show partial counts; full retry
      // happens on next pull cycle.
      debugPrint('PullEngine.pull($doctype) failed mid-pull — $e\n$st');

      // Reactive permission-skip: a genuine HTTP 403 / PermissionError
      // means the surveyor cannot read this closure-dependency doctype
      // (a Frappe framework/system table dragged in only as a Link
      // target). We DEFER the skip/auth-event decision to the end of the
      // round: add the doctype to the round-local `denied403` set and let
      // [onPermissionDeniedRound] (wired in SyncEngineBuilder) decide —
      // recording individual skips only when NO protected doctype was
      // denied this round, otherwise treating the whole round as a
      // session-level auth event. STRICTLY 403 only: timeouts,
      // SocketException, 5xx, and "no such table" all fall through
      // untouched so they stay retryable. Child doctypes never reach
      // `_runDoctype` (skipped in `run`).
      final isPermissionDenied = e is FrappeException && e.statusCode == 403;
      if (isPermissionDenied) {
        denied403.add(doctype);
      }

      notifier.value = notifier.value.updatePerDoctype(
        doctype,
        DoctypeSyncState(
          pulledCount: pulledCount,
          lastPageSize: lastPageSize,
          startedAt: startedAt,
          note: isPermissionDenied
              ? 'skipped: permission denied (403)'
              : 'failed: $e',
        ),
      );
    }
  }

  static Map<String, dynamic>? _decodeJsonOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}
