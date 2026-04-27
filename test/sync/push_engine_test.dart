import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/push_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/sync/idempotency_strategy.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/concurrency/write_queue.dart';
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
      payload: '{}',
    );
  });

  tearDown(() async => db.close());

  PushEngine buildEngine({
    required PushHttpSendFn send,
    PushServerFetchFn? serverFetcher,
    PushServerLookupByUuidFn? serverLookupByUuid,
    DocTypeMeta? customMeta,
    IdempotencyStrategy? idempotencyStrategy,
    WriteQueue Function(String doctype)? writeQueueResolver,
  }) {
    return PushEngine(
      db: db,
      outboxDao: outbox,
      attachmentDao: PendingAttachmentDao(db),
      metaDao: metaDao,
      pool: ConcurrencyPool(maxConcurrent: 2),
      notifier: SyncStateNotifier(),
      idempotencyStrategy:
          idempotencyStrategy ?? IdempotencyStrategy(serverHasDedupHook: false),
      metaResolver: (dt) async =>
          customMeta ??
          DocTypeMeta(
            name: dt,
            autoname: 'field:mobile_uuid',
            fields: [f('customer_name', 'Data')],
          ),
      childMetaResolver: (dt) async =>
          DocTypeMeta(name: dt, isTable: true, fields: const []),
      send: send,
      serverFetcher: serverFetcher ??
          (_, __) async =>
              throw StateError('serverFetcher not expected in this test'),
      serverLookupByUuid: serverLookupByUuid,
      resolveServerName: (doctype, uuid) async {
        // Resolve via the in-memory DB's table for this doctype.
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
      attachmentUploader: (file, {doctype, docname, fileName, isPrivate = true}) =>
          throw UnimplementedError('no attachments in this test'),
      writeQueueResolver: writeQueueResolver,
      attachmentBackoff: const [Duration.zero, Duration.zero, Duration.zero],
      networkBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    );
  }

  test('happy path INSERT: sends payload, writes back name + marks synced',
      () async {
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        expect(method, 'POST');
        expect(payload['doctype'], 'Customer');
        expect(payload['customer_name'], 'ACME');
        expect(payload['mobile_uuid'], 'u-c-1');
        return {'name': 'CUST-1', 'modified': '2026-01-01 00:00:00'};
      },
    );
    await engine.runOnce();
    final row = (await db.query('docs__customer')).first;
    expect(row['server_name'], 'CUST-1');
    expect(row['sync_status'], 'synced');
    expect(row['modified'], '2026-01-01 00:00:00');
    final outRows = await outbox.findByState(OutboxState.done);
    expect(outRows.length, 1);
  });

  test('UPDATE: writes back, marks synced', () async {
    await db.update(
      'docs__customer',
      {'server_name': 'CUST-1', 'modified': '2026-01-01'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    await db.update(
      'outbox',
      {'operation': 'UPDATE', 'server_name': 'CUST-1'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        expect(method, 'PUT');
        expect(serverName, 'CUST-1');
        expect(payload['modified'], '2026-01-01',
            reason: 'check_if_latest needs the local snapshot modified');
        return {'name': 'CUST-1', 'modified': '2026-01-15 10:00:00'};
      },
    );
    await engine.runOnce();
    final row = (await db.query('docs__customer')).first;
    expect(row['modified'], '2026-01-15 10:00:00');
    expect(row['sync_status'], 'synced');
  });

  test('NetworkError → retries up to N then markFailed(NETWORK)', () async {
    // Default test meta uses autoname=field:mobile_uuid → L1 path. L3's
    // pre-retry GET is gated on preRetryGetCheck, so it must NOT fire here
    // and the attempt count is purely the send retry count.
    var attempts = 0;
    final engine = buildEngine(
      send: (m, p, sn) async {
        attempts++;
        throw NetworkError(message: 'offline');
      },
    );
    await engine.runOnce();
    final row = await outbox.findById(1);
    expect(row!.state, OutboxState.failed);
    expect(row.errorCode, ErrorCode.NETWORK);
    expect(attempts, greaterThanOrEqualTo(2),
        reason: 'must retry at least once before giving up');
  });

  test('TimeoutError surfaces with TIMEOUT errorCode', () async {
    final engine = buildEngine(
      send: (m, p, sn) async => throw TimeoutError(message: 'too slow'),
    );
    await engine.runOnce();
    final row = await outbox.findById(1);
    expect(row!.errorCode, ErrorCode.TIMEOUT);
  });

  test(
    'BlockedByUpstream from UuidRewriter (unresolved Link) → markBlocked',
    () async {
      // Add an unresolved local Link to a non-existent target.
      await db.execute(
        'ALTER TABLE docs__customer ADD COLUMN territory TEXT',
      );
      await db.execute(
        'ALTER TABLE docs__customer ADD COLUMN territory__is_local INTEGER',
      );
      await db.update(
        'docs__customer',
        {'territory': 'u-tgt-not-yet', 'territory__is_local': 1},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );

      var sendCalled = false;
      final engine = buildEngine(
        customMeta: DocTypeMeta(
          name: 'Customer',
          autoname: 'field:mobile_uuid',
          fields: [
            f('customer_name', 'Data'),
            f('territory', 'Link', options: 'Territory'),
          ],
        ),
        send: (m, p, sn) async {
          sendCalled = true;
          return {'name': 'X', 'modified': '2026'};
        },
      );
      await engine.runOnce();
      expect(sendCalled, isFalse,
          reason: 'send must NOT be called when payload assembly blocks');
      final row = await outbox.findById(1);
      expect(row!.state, OutboxState.blocked);
    },
  );

  test('ServerRejection → markFailed with mapped errorCode', () async {
    final engine = buildEngine(
      send: (m, p, sn) async => throw ServerRejection(
        status: 417,
        rawBody: '{"exc_type":"MandatoryError"}',
      ),
    );
    await engine.runOnce();
    final row = await outbox.findById(1);
    expect(row!.state, OutboxState.failed);
    expect(row.errorCode, ErrorCode.MANDATORY);
  });

  test(
    'LinkExistsError on DELETE → markFailed with structured JSON',
    () async {
      await db.update(
        'docs__customer',
        {'server_name': 'CUST-1'},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );
      await db.update(
        'outbox',
        {'operation': 'DELETE', 'server_name': 'CUST-1'},
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );
      final engine = buildEngine(
        send: (m, p, sn) async => throw LinkExistsError(
          linked: {
            'Sales Invoice': ['INV-1', 'INV-2'],
          },
        ),
      );
      await engine.runOnce();
      final row = await outbox.findById(1);
      expect(row!.state, OutboxState.failed);
      expect(row.errorCode, ErrorCode.LINK_EXISTS);
      expect(row.errorMessage, contains('INV-1'));
    },
  );

  test('blocked rows are NOT dispatched', () async {
    await db.update('outbox', {'state': 'blocked'},
        where: 'id=?', whereArgs: [1]);
    var called = false;
    final engine = buildEngine(
      send: (m, p, sn) async {
        called = true;
        return {'name': 'X', 'modified': '2026'};
      },
    );
    await engine.runOnce();
    expect(called, isFalse);
  });

  test(
    'TimestampMismatch → auto-merge + retry once → succeeds',
    () async {
      await db.update(
        'docs__customer',
        {
          'server_name': 'CUST-1',
          'modified': '2026-01-01',
          'customer_name': 'LocalEdit',
        },
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );
      await db.update(
        'outbox',
        {
          'operation': 'UPDATE',
          'server_name': 'CUST-1',
          // Base snapshot: customer_name was 'ACME' when user started editing.
          'payload': '{"customer_name":"ACME"}',
        },
        where: 'mobile_uuid=?',
        whereArgs: ['u-c-1'],
      );

      var sendCalls = 0;
      var fetchCalls = 0;
      final engine = buildEngine(
        send: (m, p, sn) async {
          sendCalls++;
          if (sendCalls == 1) {
            throw TimestampMismatchError(serverModified: '2026-01-02');
          }
          // After auto-merge, the second call sends the merged payload.
          // Local edit "LocalEdit" must have survived the merge (ours
          // diverged from base 'ACME'). Server change to 'description'
          // would also be present if we modeled it.
          expect(p['customer_name'], 'LocalEdit');
          return {'name': 'CUST-1', 'modified': '2026-01-03'};
        },
        serverFetcher: (doctype, name) async {
          fetchCalls++;
          // Server's current version: name unchanged since base, modified
          // advanced.
          return {
            'name': 'CUST-1',
            'modified': '2026-01-02',
            'customer_name': 'ACME',
          };
        },
      );
      await engine.runOnce();
      expect(sendCalls, 2, reason: 'one initial + one retry after merge');
      expect(fetchCalls, 1, reason: 'serverFetcher called once for refetch');
      final row = await outbox.findById(1);
      expect(row!.state, OutboxState.done);
    },
  );

  test(
    'L1 INSERT: DuplicateEntryError → fetch by mobile_uuid + write-back',
    () async {
      // Default test setup: autoname=field:mobile_uuid → L1.
      var sendCalls = 0;
      var fetchCalls = 0;
      String? fetchedName;
      final engine = buildEngine(
        send: (m, p, sn) async {
          sendCalls++;
          throw DuplicateEntryError();
        },
        serverFetcher: (doctype, name) async {
          fetchCalls++;
          fetchedName = name;
          return {
            'name': 'u-c-1',
            'modified': '2026-01-02 00:00:00',
            'customer_name': 'ACME',
          };
        },
      );
      await engine.runOnce();
      expect(sendCalls, 1);
      expect(fetchCalls, 1, reason: 'L1 fetches existing doc by mobile_uuid');
      expect(fetchedName, 'u-c-1');
      final outRow = await outbox.findById(1);
      expect(outRow!.state, OutboxState.done);
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'u-c-1');
      expect(docRow['sync_status'], 'synced');
    },
  );

  test(
    'L2 INSERT: DuplicateEntryError(existingName) → fetch by name + write-back',
    () async {
      var fetchCalls = 0;
      String? fetchedName;
      final engine = buildEngine(
        // L2: server has dedup hook, no autoname.
        idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: true),
        customMeta: DocTypeMeta(
          name: 'Customer',
          autoname: null,
          fields: [f('customer_name', 'Data')],
        ),
        send: (m, p, sn) async =>
            throw DuplicateEntryError(existingName: 'CUST-existing-7'),
        serverFetcher: (doctype, name) async {
          fetchCalls++;
          fetchedName = name;
          return {
            'name': 'CUST-existing-7',
            'modified': '2026-01-02 00:00:00',
          };
        },
      );
      await engine.runOnce();
      expect(fetchCalls, 1);
      expect(fetchedName, 'CUST-existing-7');
      final outRow = await outbox.findById(1);
      expect(outRow!.state, OutboxState.done);
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'CUST-existing-7');
    },
  );

  test(
    'L3 INSERT: pre-retry GET finds existing → adopt, no second send',
    () async {
      var sendCalls = 0;
      var lookupCalls = 0;
      String? lookupUuid;
      final engine = buildEngine(
        // L3: stock Frappe — no dedup hook, no autoname.
        idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
        customMeta: DocTypeMeta(
          name: 'Customer',
          autoname: null,
          fields: [f('customer_name', 'Data')],
        ),
        send: (m, p, sn) async {
          sendCalls++;
          // First attempt fails network-class — server may or may not
          // have committed. The pre-retry GET below resolves the ambiguity.
          throw NetworkError(message: 'flaky');
        },
        serverLookupByUuid: (doctype, uuid) async {
          lookupCalls++;
          lookupUuid = uuid;
          return {
            'name': 'CUST-was-committed',
            'modified': '2026-01-02 00:00:00',
          };
        },
      );
      await engine.runOnce();
      expect(sendCalls, 1, reason: 'GET found row → no retry POST');
      expect(lookupCalls, 1);
      expect(lookupUuid, 'u-c-1');
      final outRow = await outbox.findById(1);
      expect(outRow!.state, OutboxState.done);
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'CUST-was-committed');
    },
  );

  test(
    'L3 INSERT: pre-retry GET finds nothing → continues retrying',
    () async {
      var sendCalls = 0;
      var lookupCalls = 0;
      final engine = buildEngine(
        idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
        customMeta: DocTypeMeta(
          name: 'Customer',
          autoname: null,
          fields: [f('customer_name', 'Data')],
        ),
        send: (m, p, sn) async {
          sendCalls++;
          throw NetworkError(message: 'flaky');
        },
        serverLookupByUuid: (doctype, uuid) async {
          lookupCalls++;
          return null; // server has nothing — original POSTs really failed
        },
      );
      await engine.runOnce();
      // 4 send attempts (1 initial + 3 retries given networkBackoff length 3).
      // Lookup runs once before each retry → 3 lookups.
      expect(sendCalls, 4);
      expect(lookupCalls, 3);
      final outRow = await outbox.findById(1);
      expect(outRow!.state, OutboxState.failed);
      expect(outRow.errorCode, ErrorCode.NETWORK);
    },
  );

  test(
    'WriteQueue: response writeback routes through per-doctype queue',
    () async {
      final resolved = <String>[];
      final queues = <String, WriteQueue>{};
      final engine = buildEngine(
        send: (m, p, sn) async =>
            {'name': 'CUST-1', 'modified': '2026-01-01 00:00:00'},
        writeQueueResolver: (doctype) {
          resolved.add(doctype);
          return queues.putIfAbsent(
            doctype,
            () => WriteQueue(db: db, doctype: doctype),
          );
        },
      );
      await engine.runOnce();
      expect(resolved, ['Customer'],
          reason: 'one queue resolved per parent doctype');
      final docRow = (await db.query('docs__customer')).first;
      expect(docRow['server_name'], 'CUST-1');
      expect(docRow['sync_status'], 'synced');
      final outRow = await outbox.findById(1);
      expect(outRow!.state, OutboxState.done);
    },
  );

  test('tier ordering: dependent row dispatches AFTER its dependency', () async {
    // Add a second outbox row that depends on the first via a UUID-shaped
    // reference in its payload. Tier 1 (dependent) must dispatch after
    // tier 0 (the original row).
    await db.insert('docs__customer', {
      'mobile_uuid': 'b1c2d3e4-f5a6-4789-89ab-cdef01234567',
      'sync_status': 'dirty',
      'local_modified': 2,
      'customer_name': 'Dependent',
    });
    await outbox.insertPending(
      doctype: 'Customer',
      mobileUuid: 'b1c2d3e4-f5a6-4789-89ab-cdef01234567',
      operation: OutboxOperation.insert,
      // Reference the first row's mobile_uuid in the payload, dressed up
      // as a uuid-v4 since the default scanner uses that regex.
      payload: '{"parent":"a1b2c3d4-e5f6-4789-89ab-cdef01234567"}',
    );
    // Update the first outbox row to use a v4-shaped uuid so the scanner
    // can match the reference.
    await db.update(
      'docs__customer',
      {'mobile_uuid': 'a1b2c3d4-e5f6-4789-89ab-cdef01234567'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );
    await db.update(
      'outbox',
      {'mobile_uuid': 'a1b2c3d4-e5f6-4789-89ab-cdef01234567'},
      where: 'mobile_uuid=?',
      whereArgs: ['u-c-1'],
    );

    final dispatchOrder = <String>[];
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        dispatchOrder.add(payload['mobile_uuid'] as String);
        return {
          'name': 'SRV-${dispatchOrder.length}',
          'modified': '2026-01-0${dispatchOrder.length}',
        };
      },
    );
    await engine.runOnce();
    expect(dispatchOrder, [
      'a1b2c3d4-e5f6-4789-89ab-cdef01234567',
      'b1c2d3e4-f5a6-4789-89ab-cdef01234567',
    ]);
  });
}
