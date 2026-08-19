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

/// Several operations can be queued for ONE document before any of them
/// reaches the server — `saveDocument` stamps a SUBMIT/CANCEL row at
/// `created_at + 1ms` precisely so it is "ordered after the INSERT/UPDATE"
/// (`offline_repository.dart`), and a delete during an in-flight INSERT
/// leaves an INSERT and a DELETE row side by side once
/// `resetInFlightToPending` runs.
///
/// Those rows are NOT mutually independent: every operation after the
/// INSERT needs the `server_name` that only the INSERT's writeback can
/// produce. The engine must therefore dispatch a single document's rows
/// sequentially, in `created_at` order.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao outbox;
  late DoctypeMetaDao metaDao;

  DocTypeMeta meta() => DocTypeMeta(
    name: 'Customer',
    autoname: 'field:mobile_uuid',
    fields: [
      DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'Name'),
      DocField(
        fieldname: 'parent_customer',
        fieldtype: 'Link',
        label: 'Parent',
        options: 'Customer',
      ),
    ],
  );

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
    for (final s in buildParentSchemaDDL(meta(), tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });
    outbox = OutboxDao(db);
    metaDao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  PushEngine buildEngine({
    required PushHttpSendFn send,
    int maxConcurrent = 4,
    WriteQueueResolver? writeQueueResolver,
  }) => PushEngine(
    writeQueueResolver: writeQueueResolver,
    db: db,
    outboxDao: outbox,
    attachmentDao: PendingAttachmentDao(db),
    metaDao: metaDao,
    pool: ConcurrencyPool(maxConcurrent: maxConcurrent),
    notifier: SyncStateNotifier(),
    idempotencyStrategy: IdempotencyStrategy(serverHasDedupHook: false),
    metaResolver: (_) async => meta(),
    childMetaResolver: (dt) async =>
        DocTypeMeta(name: dt, isTable: true, fields: const []),
    send: send,
    serverFetcher: (_, _) async => throw StateError('not expected'),
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
            throw UnimplementedError(),
    attachmentBackoff: const [Duration.zero, Duration.zero, Duration.zero],
    networkBackoff: const [Duration.zero, Duration.zero, Duration.zero],
  );

  Future<void> seedDoc(String uuid, {String? parentUuid, int? parentIsLocal}) {
    return db.insert('docs__customer', {
      'mobile_uuid': uuid,
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer_name': uuid,
      'parent_customer': parentUuid,
      'parent_customer__is_local': parentIsLocal,
    });
  }

  final base = DateTime.utc(2026, 1, 1);

  Future<void> queue(
    String uuid,
    OutboxOperation op, {
    required int msOffset,
  }) => outbox.insertPending(
    doctype: 'Customer',
    mobileUuid: uuid,
    operation: op,
    createdAt: base.add(Duration(milliseconds: msOffset)),
  );

  test('SUBMIT queued after INSERT dispatches after it, with the '
      'server name the INSERT produced', () async {
    await seedDoc('u-s');
    await queue('u-s', OutboxOperation.insert, msOffset: 0);
    await queue('u-s', OutboxOperation.submit, msOffset: 1);

    final order = <String>[];
    final serverNameByVerb = <String, String?>{};
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        order.add(method);
        serverNameByVerb[method] = serverName;
        return {'name': 'CUST-S', 'modified': '2026-01-01 00:00:00'};
      },
    );

    await engine.runOnce();

    expect(order, ['POST', 'SUBMIT']);
    expect(
      serverNameByVerb['SUBMIT'],
      'CUST-S',
      reason:
          'SUBMIT must see the server_name the INSERT wrote back; '
          'production dispatch does `serverName!` and would throw on null',
    );
    expect(await db.query('outbox'), isEmpty);
  });

  test('DELETE queued after INSERT dispatches after it and leaves no '
      'orphan outbox row', () async {
    await seedDoc('u-d');
    await queue('u-d', OutboxOperation.insert, msOffset: 0);
    await queue('u-d', OutboxOperation.delete, msOffset: 1);

    final order = <String>[];
    final serverNameByVerb = <String, String?>{};
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        order.add(method);
        serverNameByVerb[method] = serverName;
        if (method == 'DELETE') return const <String, dynamic>{};
        return {'name': 'CUST-D', 'modified': '2026-01-01 00:00:00'};
      },
    );

    await engine.runOnce();

    expect(order, ['POST', 'DELETE']);
    expect(serverNameByVerb['DELETE'], 'CUST-D');
    expect(
      await db.query('outbox'),
      isEmpty,
      reason:
          'a DELETE that runs first destroys the local row, so the '
          'INSERT then fails with "Local row missing" and its row is '
          'stranded in the outbox forever',
    );
    expect(await db.query('docs__customer'), isEmpty);
  });

  test('same-doctype INSERTs for DIFFERENT documents stay chained '
      'sequentially (naming-series guard)', () async {
    await seedDoc('u-a');
    await seedDoc('u-b');
    await queue('u-a', OutboxOperation.insert, msOffset: 0);
    await queue('u-b', OutboxOperation.insert, msOffset: 1);

    var concurrent = 0;
    var maxConcurrent = 0;
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        concurrent++;
        maxConcurrent = maxConcurrent > concurrent ? maxConcurrent : concurrent;
        await Future<void>.delayed(Duration.zero);
        concurrent--;
        return {
          'name': 'CUST-${payload['mobile_uuid']}',
          'modified': '2026-01-01 00:00:00',
        };
      },
    );

    await engine.runOnce();

    expect(maxConcurrent, 1);
  });

  test('self-referencing Link across two documents still orders the '
      'parent before the child', () async {
    await seedDoc('u-parent');
    await seedDoc('u-child', parentUuid: 'u-parent', parentIsLocal: 1);
    // Child's row is deliberately OLDER — dependency order must win.
    await queue('u-child', OutboxOperation.insert, msOffset: 0);
    await queue('u-parent', OutboxOperation.insert, msOffset: 1);

    final order = <String>[];
    final linkSent = <String, Object?>{};
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        final uuid = payload['mobile_uuid'] as String;
        order.add(uuid);
        linkSent[uuid] = payload['parent_customer'];
        return {'name': 'CUST-$uuid', 'modified': '2026-01-01 00:00:00'};
      },
    );

    await engine.runOnce();

    expect(order, ['u-parent', 'u-child']);
    expect(linkSent['u-child'], 'CUST-u-parent');
  });

  // Ordering alone is not enough. Chaining only helps when both rows are
  // pending in the same drain AND the INSERT succeeds. These two cover the
  // routes it cannot: the INSERT fails inside the chain, and the INSERT was
  // already parked in `failed` by an earlier drain so no chain exists at all.
  // Production's dispatch does `serverName!`, so both used to surface as a
  // TypeError recorded as markFailed(UNKNOWN).

  test('DELETE behind an INSERT that FAILS is blocked, never sent', () async {
    await seedDoc('u-d');
    await queue('u-d', OutboxOperation.insert, msOffset: 0);
    await queue('u-d', OutboxOperation.delete, msOffset: 1);

    final calls = <List<Object?>>[];
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        calls.add([method, serverName]);
        if (method == 'POST') throw NetworkError(message: 'offline');
        return const <String, dynamic>{};
      },
    );

    await engine.runOnce();

    expect(
      calls.where((c) => c[0] != 'POST'),
      isEmpty,
      reason: 'a DELETE with no server_name must not reach the wire',
    );
    final rows = await db.query('outbox', orderBy: 'created_at ASC');
    expect(rows.map((r) => r['state']), ['failed', 'blocked']);
    expect(
      await db.query('docs__customer'),
      isNotEmpty,
      reason: 'the local mirror must survive a DELETE that never dispatched',
    );
  });

  test('DELETE alone in its tier, INSERT already failed in an earlier '
      'drain, is blocked', () async {
    await seedDoc('u-d');
    final insertId = await outbox.insertPending(
      doctype: 'Customer',
      mobileUuid: 'u-d',
      operation: OutboxOperation.insert,
      createdAt: base,
    );
    await outbox.markFailed(
      insertId,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'offline',
    );
    await queue('u-d', OutboxOperation.delete, msOffset: 1);

    final calls = <String>[];
    final engine = buildEngine(
      send: (method, payload, serverName) async {
        calls.add(method);
        return const <String, dynamic>{};
      },
    );

    await engine.runOnce();

    expect(calls, isEmpty);
    final deleteRow = (await db.query(
      'outbox',
      where: 'operation = ?',
      whereArgs: ['DELETE'],
    )).single;
    expect(deleteRow['state'], 'blocked');
  });

  test('a later operation on an earlier document does not overtake an '
      'earlier operation on a later document', () async {
    await seedDoc('u-a');
    await seedDoc('u-b');
    await queue('u-a', OutboxOperation.insert, msOffset: 0);
    await queue('u-b', OutboxOperation.insert, msOffset: 1);
    await queue('u-a', OutboxOperation.submit, msOffset: 2);

    final order = <String>[];
    final engine = buildEngine(
      maxConcurrent: 1,
      send: (method, payload, serverName) async {
        order.add('${payload['mobile_uuid']}/$method');
        return {
          'name': 'SRV-${payload['mobile_uuid']}',
          'modified': '2026-01-01 00:00:00',
        };
      },
    );

    await engine.runOnce();

    expect(
      order,
      ['u-a/POST', 'u-b/POST', 'u-a/SUBMIT'],
      reason:
          'rows must leave the outbox in created_at order; chaining a '
          "document's rows together must not hoist its later operations "
          'ahead of an earlier row belonging to another document',
    );
  });

  test('ordering holds through the production WriteQueue path', () async {
    await seedDoc('u-s');
    await queue('u-s', OutboxOperation.insert, msOffset: 0);
    await queue('u-s', OutboxOperation.submit, msOffset: 1);

    final queues = <String, WriteQueue>{};
    final order = <String>[];
    final serverNameByVerb = <String, String?>{};
    final engine = buildEngine(
      writeQueueResolver: (doctype) => queues.putIfAbsent(
        doctype,
        () => WriteQueue(db: db, doctype: doctype),
      ),
      send: (method, payload, serverName) async {
        order.add(method);
        serverNameByVerb[method] = serverName;
        return {'name': 'CUST-S', 'modified': '2026-01-01 00:00:00'};
      },
    );

    await engine.runOnce();

    expect(order, ['POST', 'SUBMIT']);
    expect(
      serverNameByVerb['SUBMIT'],
      'CUST-S',
      reason:
          'WriteQueue resolves its completer only after COMMIT, so the '
          'INSERT writeback must be visible to the SUBMIT that follows it',
    );
  });
}
