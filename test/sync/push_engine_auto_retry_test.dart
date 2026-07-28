// Fix B (T-B1..T-B4, T-B6) — the push engine auto-requeues transient-failed
// outbox rows on the next drain (no user action), respects the attempt cap,
// leaves genuine server rejections failed, and runs the requeue AFTER the
// supersede pass so a superseded failed row is never double-dispatched.
//
// Scaffolding mirrors `push_engine_test.dart` (in-memory docs__customer +
// a single seeded INSERT outbox row for u-c-1).
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/sync/push_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

const _ok = {'name': 'CUST-1', 'modified': '2026-01-01 00:00:00'};

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
      fields: [f('customer_name', 'Data')],
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
    });
    outbox = OutboxDao(db);
    metaDao = DoctypeMetaDao(db);
    await outbox.insertPending(
      doctype: 'Customer',
      mobileUuid: 'u-c-1',
      operation: OutboxOperation.insert,
    );
  });

  tearDown(() async => db.close());

  PushEngine buildEngine({
    required PushHttpSendFn send,
    int maxAutoRetryAttempts = 5,
  }) {
    return PushEngine(
      db: db,
      outboxDao: outbox,
      attachmentDao: PendingAttachmentDao(db),
      metaDao: metaDao,
      pool: ConcurrencyPool(maxConcurrent: 2),
      notifier: SyncStateNotifier(),
      maxAutoRetryAttempts: maxAutoRetryAttempts,
      idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
      metaResolver: (dt) async => DocTypeMeta(
        name: dt,
        autoname: 'field:mobile_uuid',
        fields: [f('customer_name', 'Data')],
      ),
      childMetaResolver: (dt) async =>
          DocTypeMeta(name: dt, isTable: true, fields: const []),
      send: send,
      serverFetcher: (_, _) async =>
          throw StateError('serverFetcher not expected in this test'),
      serverLookupByUuid: null,
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
      attachmentUploader:
          (file, {doctype, docname, fileName, isPrivate = true}) =>
              throw UnimplementedError('no attachments in this test'),
      attachmentBackoff: const [Duration.zero, Duration.zero, Duration.zero],
      networkBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    );
  }

  test(
    'T-B1: a transient (NETWORK) failed row auto-requeues on the next drain and succeeds',
    () async {
      // Persistent network failure → markFailed(NETWORK).
      await buildEngine(
        send: (m, p, sn) async => throw NetworkException('offline'),
      ).runOnce();

      var row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      expect(row.errorCode, ErrorCode.NETWORK, reason: 'translated at the send boundary');
      expect(row.attempts, 0, reason: 'markFailed must not touch the auto-retry counter');

      // Next drain, send now succeeds → the failed row is requeued WITHOUT any
      // user action, dispatched, and deleted (markDone).
      var dispatched = 0;
      await buildEngine(
        send: (m, p, sn) async {
          dispatched++;
          return _ok;
        },
      ).runOnce();

      expect(dispatched, 1, reason: 'auto-requeued failed row was dispatched');
      expect(await outbox.findById(1), isNull, reason: 'success deletes the row');
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
    },
  );

  test(
    'T-B2: a server rejection (VALIDATION) stays failed and is never re-dispatched',
    () async {
      var dispatched = 0;
      final engine = buildEngine(
        send: (m, p, sn) async {
          dispatched++;
          throw ValidationException('Required', {'name': 'required'});
        },
      );

      await engine.runOnce();
      expect(dispatched, 1);
      var row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      expect(row.errorCode, ErrorCode.VALIDATION);
      expect(row.attempts, 0);

      // Genuine rejections must never loop, no matter how many drains run.
      await engine.runOnce();
      await engine.runOnce();
      expect(dispatched, 1, reason: 'VALIDATION is excluded from auto-requeue');
      row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      expect(row.attempts, 0);
    },
  );

  test(
    'T-B3: the attempt cap bounds auto-requeue; user resetToPending restores the budget',
    () async {
      // AUTH (401) is transient but NOT network-retried inside _dispatchOnce,
      // so each runOnce is exactly one dispatch — clean cap accounting.
      var dispatched = 0;
      final engine = buildEngine(
        maxAutoRetryAttempts: 2,
        send: (m, p, sn) async {
          dispatched++;
          throw AuthException('session expired', 401);
        },
      );

      // #1 dispatch → failed(attempts 0); #2 requeue(attempts 1) → dispatch →
      // failed; #3 requeue(attempts 2) → dispatch → failed; #4 at cap → NO
      // dispatch. Initial + exactly 2 auto-retries = 3 dispatches.
      for (var i = 0; i < 4; i++) {
        await engine.runOnce();
      }
      expect(dispatched, 3, reason: 'initial dispatch + exactly maxAutoRetryAttempts(2) retries');
      var row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      expect(row.attempts, 2);

      // A user-initiated retry zeroes the counter → budget restored.
      await outbox.resetToPending(1);
      expect((await outbox.findById(1))!.attempts, 0);
      await engine.runOnce();
      expect(dispatched, 4, reason: 'row is retryable again after user reset');
    },
  );

  test(
    'T-B4: supersede runs before requeue — a superseded failed row is not double-dispatched',
    () async {
      // An OLDER failed row for the SAME tuple as the seeded newer pending row.
      final oldId = await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-c-1',
        operation: OutboxOperation.insert,
        createdAt: DateTime.utc(2020, 1, 1),
      );
      await outbox.markFailed(oldId, errorCode: ErrorCode.NETWORK, errorMessage: 'boom');

      var dispatched = 0;
      await buildEngine(
        send: (m, p, sn) async {
          dispatched++;
          return _ok;
        },
      ).runOnce();

      // If requeue ran BEFORE supersede, oldId would flip to a second pending
      // row → 2 dispatches. Ordering guarantees exactly one.
      expect(dispatched, 1, reason: 'superseded failed row deleted before requeue');
      expect(await outbox.findById(oldId), isNull, reason: 'supersede removed the older failed row');
      expect(await outbox.findByState(OutboxState.pending), isEmpty);
      expect(await outbox.findByState(OutboxState.failed), isEmpty);
    },
  );

  test(
    'T-B6: a 401 (AUTH) failure auto-requeues and succeeds once the bearer is restored',
    () async {
      // Session expired mid-push → AUTH.
      await buildEngine(
        send: (m, p, sn) async => throw AuthException('session expired', 401),
      ).runOnce();

      var row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      expect(row.errorCode, ErrorCode.AUTH, reason: 'the Fix A×Fix B seam: 401 → AUTH');
      expect(row.attempts, 0);

      // Fix A's single-flight refresh restores the bearer; the next drain
      // recovers the row with no user action.
      var dispatched = 0;
      await buildEngine(
        send: (m, p, sn) async {
          dispatched++;
          return _ok;
        },
      ).runOnce();

      expect(dispatched, 1);
      expect(await outbox.findById(1), isNull);
    },
  );
}
