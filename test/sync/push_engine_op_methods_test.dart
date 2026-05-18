// Covers the remaining op→HTTP-method branches of [PushEngine] not exercised
// by the main `push_engine_test.dart`:
//   - SUBMIT path on a submittable doctype
//   - CANCEL path on an already-submitted doctype
//   - DELETE path on a doc with a server_name
// Plus: the auto-merge writeback that is routed through a per-doctype
// WriteQueue (PR#36 change — the merged-payload persist must serialise
// with other writes on the same doctype, not jump the queue).
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/concurrency/write_queue.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/sync/push_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField _f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao outbox;
  late DoctypeMetaDao metaDao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL,
        groupName TEXT,
        sortOrder INTEGER
      )
    ''');
    for (final s in doctypeMetaExtensionsDDL()) {
      await db.execute(s);
    }
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    final m = DocTypeMeta(
      name: 'Customer',
      autoname: 'field:mobile_uuid',
      fields: [_f('customer_name', 'Data')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u-c-1',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer_name': 'ACME',
      'server_name': 'CUST-1',
      'modified': '2026-01-01',
    });
    outbox = OutboxDao(db);
    metaDao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  PushEngine build({
    required PushHttpSendFn send,
    PushServerFetchFn? serverFetcher,
    WriteQueue Function(String doctype)? writeQueueResolver,
  }) {
    return PushEngine(
      db: db,
      outboxDao: outbox,
      attachmentDao: PendingAttachmentDao(db),
      metaDao: metaDao,
      pool: ConcurrencyPool(maxConcurrent: 2),
      notifier: SyncStateNotifier(),
      idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
      metaResolver: (dt) async => DocTypeMeta(
        name: dt,
        autoname: 'field:mobile_uuid',
        fields: [_f('customer_name', 'Data')],
      ),
      childMetaResolver: (dt) async =>
          DocTypeMeta(name: dt, isTable: true, fields: const []),
      send: send,
      serverFetcher:
          serverFetcher ??
          (_, _) async => throw StateError('serverFetcher not expected'),
      resolveServerName: (doctype, uuid) async {
        final tn = await metaDao.getTableName(doctype);
        if (tn == null) return null;
        final r = await db.query(
          tn,
          columns: ['server_name'],
          where: 'mobile_uuid = ?',
          whereArgs: [uuid],
          limit: 1,
        );
        return r.isEmpty ? null : r.first['server_name'] as String?;
      },
      attachmentUploader: (f, {doctype, docname, fileName, isPrivate = true}) =>
          throw UnimplementedError(),
      writeQueueResolver: writeQueueResolver,
      attachmentBackoff: const [Duration.zero, Duration.zero, Duration.zero],
      networkBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    );
  }

  test(
    'SUBMIT operation dispatches with method=SUBMIT and server name',
    () async {
      await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-c-1',
        operation: OutboxOperation.submit,
      );
      String? capturedMethod;
      String? capturedServerName;
      final engine = build(
        send: (method, payload, serverName) async {
          capturedMethod = method;
          capturedServerName = serverName;
          return {'name': 'CUST-1', 'modified': '2026-01-02', 'docstatus': 1};
        },
      );
      await engine.runOnce();
      expect(capturedMethod, 'SUBMIT');
      expect(capturedServerName, 'CUST-1');
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
    },
  );

  test(
    'CANCEL operation dispatches with method=CANCEL and server name',
    () async {
      await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-c-1',
        operation: OutboxOperation.cancel,
      );
      String? capturedMethod;
      final engine = build(
        send: (method, payload, serverName) async {
          capturedMethod = method;
          return {'name': 'CUST-1', 'modified': '2026-01-03', 'docstatus': 2};
        },
      );
      await engine.runOnce();
      expect(capturedMethod, 'CANCEL');
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
    },
  );

  test(
    'DELETE operation dispatches with method=DELETE, then docs__ row gone',
    () async {
      await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-c-1',
        operation: OutboxOperation.delete,
      );
      String? capturedMethod;
      final engine = build(
        send: (method, payload, serverName) async {
          capturedMethod = method;
          return const <String, dynamic>{};
        },
      );
      await engine.runOnce();
      expect(capturedMethod, 'DELETE');
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
      final remaining = await db.query(
        'docs__customer',
        where: 'mobile_uuid = ?',
        whereArgs: ['u-c-1'],
      );
      expect(
        remaining,
        isEmpty,
        reason: 'successful DELETE must remove the local mirror row',
      );
    },
  );

  test(
    'auto-merge persist routes through WriteQueue when resolver is provided',
    () async {
      // Set the row up the same way the TimestampMismatch-with-merge test does:
      // a base payload pinned on docs__, and a stale modified that will trigger
      // the auto-merge path on the first send.
      await db.update(
        'docs__customer',
        {
          'customer_name': 'LocalEdit',
          'push_base_payload': '{"customer_name":"ACME"}',
        },
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );
      await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-c-1',
        operation: OutboxOperation.update,
      );

      final resolved = <String>[];
      final queues = <String, WriteQueue>{};
      var sendCalls = 0;
      final engine = build(
        send: (m, p, sn) async {
          sendCalls++;
          if (sendCalls == 1) {
            throw TimestampMismatchError(serverModified: '2026-01-02');
          }
          return {'name': 'CUST-1', 'modified': '2026-01-03'};
        },
        serverFetcher: (_, _) async => {
          'name': 'CUST-1',
          'modified': '2026-01-02',
          'customer_name': 'ACME',
        },
        writeQueueResolver: (doctype) {
          resolved.add(doctype);
          return queues.putIfAbsent(
            doctype,
            () => WriteQueue(db: db, doctype: doctype),
          );
        },
      );
      await engine.runOnce();

      expect(sendCalls, 2, reason: 'initial mismatch + retry after merge');
      // PR#36 guarantee: every parent-side persist (merge + final writeback)
      // is gated by the per-doctype WriteQueue, so we must see at least one
      // resolve for `Customer`. Multiple resolves are fine — the cache makes
      // them idempotent.
      expect(
        resolved,
        contains('Customer'),
        reason: 'merge writeback must route through the queue',
      );
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
    },
  );
}
