import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../concurrency/concurrency_pool.dart';
import '../concurrency/write_queue.dart';
import '../database/daos/doctype_meta_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../database/table_name.dart';
import '../models/closure_result.dart';
import '../models/dep_graph.dart';
import '../models/meta_resolver.dart';
import 'cursor.dart';
import 'pull_apply.dart';
import 'pull_page_fetcher.dart';
import 'sync_state.dart';
import 'sync_state_notifier.dart';

/// Back-compat alias. Use [MetaResolverFn] directly in new code.
typedef MetaResolver = MetaResolverFn;

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
  });

  Future<void> run(ClosureResult closure) async {
    notifier.value = notifier.value.copyWith(isPulling: true);
    final futures = <Future<void>>[];
    for (final dt in closure.doctypes) {
      if (closure.childDoctypes.contains(dt)) continue;
      futures.add(pool.submit<void>(() => _runDoctype(dt, closure)));
    }
    await Future.wait(futures);
    notifier.value = notifier.value.copyWith(
      isPulling: false,
      lastSyncAt: DateTime.now().toUtc(),
    );
  }

  Future<void> _runDoctype(String doctype, ClosureResult closure) async {
    if (await outboxDao.hasActivePushFor(doctype)) {
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

    final parentTable = await metaDao.getTableName(doctype) ??
        normalizeDoctypeTableName(doctype);

    // Resolve child metas for every Table / Table MultiSelect outgoing edge.
    final childInfo = <String, PullApplyChildInfo>{};
    final graph = closure.graph[doctype];
    if (graph != null) {
      for (final edge
          in graph.outgoing.where((e) => e.kind == DepEdgeKind.child)) {
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
      }

      // Cursor is persisted only when the doctype drains fully — partial
      // pulls leave the on-disk cursor untouched so a relaunch resumes
      // from the last fully-applied page.
      final cursorJson = scratch.toJson();
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
          lastOkCursor: scratch,
        ),
      );
    } catch (e) {
      // Mid-pull failure: do NOT persist cursor. Surface the doctype's
      // current progress so the UI can show partial counts; full retry
      // happens on next pull cycle.
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
