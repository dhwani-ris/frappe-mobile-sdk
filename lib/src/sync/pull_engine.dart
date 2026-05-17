import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../concurrency/concurrency_pool.dart';
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

    final parentTable = await metaDao.tableNameFor(doctype);

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

    try {
      while (true) {
        final result = await fetcher.fetch(
          doctype: doctype,
          meta: meta,
          cursor: scratch,
          pageSize: pageSize,
        );
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
    } catch (e, st) {
      // Mid-pull failure: do NOT persist cursor. Surface the doctype's
      // current progress so the UI can show partial counts; full retry
      // happens on next pull cycle.
      debugPrint('PullEngine.pull($doctype) failed mid-pull — $e\n$st');
      notifier.value = notifier.value.updatePerDoctype(
        doctype,
        DoctypeSyncState(
          pulledCount: pulledCount,
          lastPageSize: lastPageSize,
          startedAt: startedAt,
          note: 'failed: $e',
        ),
      );
    }
  }

  static Map<String, dynamic>? _decodeJsonOrNull(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}
