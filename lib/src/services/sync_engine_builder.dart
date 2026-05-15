import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../api/client.dart';
import '../concurrency/concurrency_pool.dart';
import '../concurrency/device_tier.dart';
import '../concurrency/write_queue.dart';
import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../database/sqlite_utils.dart';
import '../database/table_name.dart';
import '../models/meta_resolver.dart';
import '../sync/idempotency_strategy.dart';
import '../sync/pull_engine.dart';
import '../sync/pull_page_fetcher.dart';
import '../sync/push_engine.dart';
import '../sync/sync_state_notifier.dart';
import 'sync_controller.dart';

/// Bundle of the engines + façade that `FrappeSDK` stashes after wiring.
class SyncEnginePack {
  final SyncStateNotifier notifier;
  final ConcurrencyPool pullPool;
  final ConcurrencyPool pushPool;
  final PushEngine pushEngine;
  final PullEngine pullEngine;
  final SyncController controller;

  const SyncEnginePack({
    required this.notifier,
    required this.pullPool,
    required this.pushPool,
    required this.pushEngine,
    required this.pullEngine,
    required this.controller,
  });
}

/// One-shot wiring helper. Pure-construction; no side effects beyond the
/// objects it returns.
class SyncEngineBuilder {
  static Future<SyncEnginePack> build({
    required AppDatabase database,
    required FrappeClient client,
    required MetaResolverFn metaResolver,
    required Future<Set<String>> Function() runPullFn,
    required Future<void> Function(String doctype, Map<String, dynamic> doc)
    applyServerDoc,
    required Future<void> Function(Set<String> doctypes) runPullForDoctypes,
    bool serverHasDedupHook = false,
    int? concurrencyOverride,
    SyncStateNotifier? sharedNotifier,
    SchemaReconcilerFn? schemaReconciler,
  }) async {
    final notifier = sharedNotifier ?? SyncStateNotifier();
    final tier = await DeviceTier.detect(override: concurrencyOverride);
    final pullPool = ConcurrencyPool(maxConcurrent: tier);
    final pushPool = ConcurrencyPool(maxConcurrent: tier);

    final rawDb = database.rawDatabase;
    final outboxDao = OutboxDao(rawDb);
    final attachmentDao = PendingAttachmentDao(rawDb);
    final metaDao = database.doctypeMetaDao;

    // ----- HTTP send callback -----
    Future<Map<String, dynamic>> send(
      String method,
      Map<String, Object?> payload,
      String? serverName,
    ) async {
      final doctype = payload['doctype'] as String;
      switch (method) {
        case 'POST':
          return client.document.createDocument(
            doctype,
            Map<String, dynamic>.from(payload),
          );
        case 'PUT':
          return client.document.updateDocument(
            doctype,
            serverName!,
            Map<String, dynamic>.from(payload),
          );
        case 'SUBMIT':
          return client.document.submitDocument(doctype, serverName!);
        case 'CANCEL':
          return client.document.cancelDocument(doctype, serverName!);
        case 'DELETE':
          await client.document.deleteDocument(doctype, serverName!);
          return const <String, dynamic>{};
        default:
          throw StateError('SyncEngineBuilder.send: unknown method "$method"');
      }
    }

    // ----- serverFetcher -----
    Future<Map<String, dynamic>> serverFetcher(
      String doctype,
      String serverName,
    ) => client.doctype.getByName(doctype, serverName);

    // ----- serverLookupByUuid (L3 idempotency probe) -----
    Future<Map<String, dynamic>?> serverLookupByUuid(
      String doctype,
      String mobileUuid,
    ) async {
      try {
        final list = await client.doctype.list(
          doctype,
          filters: [
            ['mobile_uuid', '=', mobileUuid],
          ],
          limitPageLength: 1,
        );
        if (list.isEmpty) return null;
        final first = list.first;
        if (first is Map) {
          return Map<String, dynamic>.from(first);
        }
        return null;
      } catch (e, st) {
        // ignore: avoid_print
        print(
          'SyncEngineBuilder.serverLookupByUuid: lookup failed for '
          '$doctype/$mobileUuid — $e\n$st',
        );
        return null;
      }
    }

    // ----- attachment uploader -----
    Future<Map<String, dynamic>> attachmentUploader(
      File file, {
      String? doctype,
      String? docname,
      String? fileName,
      bool isPrivate = true,
    }) => client.attachment.uploadFile(
      file,
      fileName: fileName,
      doctype: doctype,
      docname: docname,
      isPrivate: isPrivate,
    );

    // ----- resolveServerName -----
    Future<String?> resolveServerName(
      String targetDoctype,
      String mobileUuid,
    ) => _resolveServerNameFor(rawDb, targetDoctype, mobileUuid);

    // ----- Per-doctype WriteQueue cache -----
    final writeQueueCache = <String, WriteQueue>{};
    WriteQueue writeQueueResolver(String doctype) {
      return writeQueueCache.putIfAbsent(
        doctype,
        () => WriteQueue(db: rawDb, doctype: doctype),
      );
    }

    final idempotencyStrategy = IdempotencyStrategy(
      serverHasDedupHook: serverHasDedupHook,
      onInitWarning: (msg) {
        // ignore: avoid_print
        print('IdempotencyStrategy: $msg');
      },
    );

    final pushEngine = PushEngine(
      db: rawDb,
      outboxDao: outboxDao,
      attachmentDao: attachmentDao,
      metaDao: metaDao,
      pool: pushPool,
      notifier: notifier,
      idempotencyStrategy: idempotencyStrategy,
      metaResolver: metaResolver,
      childMetaResolver: metaResolver,
      send: send,
      serverFetcher: serverFetcher,
      serverLookupByUuid: serverLookupByUuid,
      resolveServerName: resolveServerName,
      attachmentUploader: attachmentUploader,
      writeQueueResolver: writeQueueResolver,
    );

    // PullEngine is built but not auto-invoked. The list-http callback
    // wraps client.doctype.list; PullPageFetcher uses it when the engine
    // eventually runs.
    Future<List<Map<String, dynamic>>> listHttp(
      String doctype,
      Map<String, Object?> params,
    ) async {
      final result = await client.doctype.list(
        doctype,
        filters: (params['filters'] as List?)?.cast<List<dynamic>>(),
        fields: (params['fields'] as List?)?.cast<String>(),
        orderBy: params['order_by'] as String?,
        limitPageLength: params['limit_page_length'] as int? ?? 500,
        limitStart: params['limit_start'] as int? ?? 0,
      );
      return result
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }

    final pullEngine = PullEngine(
      db: rawDb,
      metaDao: metaDao,
      outboxDao: outboxDao,
      pool: pullPool,
      fetcher: PullPageFetcher(listHttp: listHttp),
      pageSize: 500,
      notifier: notifier,
      metaResolver: metaResolver,
      writeQueueResolver: writeQueueResolver,
      schemaReconciler: schemaReconciler,
    );

    final controller = SyncController(
      outboxDao: outboxDao,
      notifier: notifier,
      runPull: runPullFn,
      runPush: () => pushEngine.runOnce(),
      runPullForDoctypes: runPullForDoctypes,
      fetchSingleDoc: serverFetcher,
      applySingleDoc: applyServerDoc,
      resolveServerName: resolveServerName,
    );

    return SyncEnginePack(
      notifier: notifier,
      pullPool: pullPool,
      pushPool: pushPool,
      pushEngine: pushEngine,
      pullEngine: pullEngine,
      controller: controller,
    );
  }
}

/// Test seam — `_resolveServerNameFor` is private; expose via this thin
/// `@visibleForTesting` wrapper so the resolver's edge cases can be
/// exercised directly without driving a full PushEngine retry path.
@visibleForTesting
Future<String?> debugResolveServerNameFor(
  Database db,
  String targetDoctype,
  String mobileUuid,
) => _resolveServerNameFor(db, targetDoctype, mobileUuid);

/// Looks up a target doctype's `server_name` from its `docs__<target>`
/// row keyed by `mobile_uuid`. Returns null when:
///  - the per-doctype table has not been provisioned yet
///  - no row exists for the given uuid
///  - the row exists but `server_name` is NULL (the doc has not been pushed)
Future<String?> _resolveServerNameFor(
  Database db,
  String targetDoctype,
  String mobileUuid,
) async {
  final tableName = normalizeDoctypeTableName(targetDoctype);
  if (!await sqliteTableExists(db, tableName)) {
    // ignore: avoid_print
    print(
      '[DIAG resolveServerName] table_missing target=$targetDoctype '
      'table=$tableName uuid=$mobileUuid',
    );
    return null;
  }
  // Diagnostic: dump every row matching this uuid. Use SELECT * so it works
  // for both parent and child docs__ tables (child has parent_uuid/idx, parent
  // doesn't). Wrap in try/catch so a diag failure never breaks the resolver.
  try {
    final allRows = await db.query(
      tableName,
      where: 'mobile_uuid = ?',
      whereArgs: [mobileUuid],
    );
    final summary = allRows
        .map(
          (r) => {
            'mobile_uuid': r['mobile_uuid'],
            'server_name': r['server_name'],
            if (r.containsKey('parent_uuid')) 'parent_uuid': r['parent_uuid'],
            if (r.containsKey('parentfield')) 'parentfield': r['parentfield'],
            if (r.containsKey('idx')) 'idx': r['idx'],
            if (r.containsKey('sync_status')) 'sync_status': r['sync_status'],
          },
        )
        .toList();
    // ignore: avoid_print
    print(
      '[DIAG resolveServerName] target=$targetDoctype uuid=$mobileUuid '
      'matchingRows=${allRows.length} rows=$summary',
    );
  } catch (e, st) {
    // ignore: avoid_print
    print(
      '[DIAG resolveServerName] dump_failed target=$targetDoctype '
      'uuid=$mobileUuid err=$e\n$st',
    );
  }
  final rows = await db.query(
    tableName,
    columns: ['server_name'],
    where: 'mobile_uuid = ? AND server_name IS NOT NULL',
    whereArgs: [mobileUuid],
    limit: 1,
  );
  if (rows.isEmpty) {
    // ignore: avoid_print
    print(
      '[DIAG resolveServerName] returning_null target=$targetDoctype '
      'uuid=$mobileUuid (no row with non-null server_name)',
    );
    return null;
  }
  final result = rows.first['server_name'] as String?;
  // ignore: avoid_print
  print(
    '[DIAG resolveServerName] resolved target=$targetDoctype '
    'uuid=$mobileUuid → $result',
  );
  return result;
}
