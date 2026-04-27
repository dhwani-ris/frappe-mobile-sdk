import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/migrations/v1_to_v2.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta customerMeta() => DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'N'),
        DocField(fieldname: 'age', fieldtype: 'Int', label: 'A'),
      ],
    );

DocTypeMeta orderMeta() => DocTypeMeta(
      name: 'Sales Order',
      fields: [
        DocField(
            fieldname: 'customer',
            fieldtype: 'Link',
            label: 'C',
            options: 'Customer'),
        DocField(
            fieldname: 'items',
            fieldtype: 'Table',
            label: 'I',
            options: 'Sales Order Item'),
      ],
    );

DocTypeMeta orderItemMeta() => DocTypeMeta(
      name: 'Sales Order Item',
      fields: [
        DocField(fieldname: 'item_code', fieldtype: 'Data', label: 'I'),
        DocField(fieldname: 'qty', fieldtype: 'Int', label: 'Q'),
      ],
    );

Future<DocTypeMeta> fakeMetaFetcher(String doctype) async {
  switch (doctype) {
    case 'Customer':
      return customerMeta();
    case 'Sales Order':
      return orderMeta();
    case 'Sales Order Item':
      return orderItemMeta();
  }
  throw ArgumentError('unknown doctype: $doctype');
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE documents (
        localId TEXT PRIMARY KEY,
        doctype TEXT NOT NULL,
        serverId TEXT,
        dataJson TEXT NOT NULL,
        status TEXT NOT NULL,
        modified INTEGER
      )
    ''');
    // Mirrors AppDatabase._onCreate exactly so the test exercises real schema.
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
    for (final stmt in doctypeMetaExtensionsDDL()) {
      await db.execute(stmt);
    }
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
  });

  tearDown(() async => db.close());

  test('migrates clean customer row into docs__customer as synced', () async {
    await db.insert('documents', {
      'localId': 'uuid-1',
      'doctype': 'Customer',
      'serverId': 'CUST-1',
      'status': 'clean',
      'modified': 1700000000,
      'dataJson': jsonEncode({'customer_name': 'ACME', 'age': 10}),
    });

    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final rows = await db.query('docs__customer');
    expect(rows.length, 1);
    expect(rows.first['mobile_uuid'], 'uuid-1');
    expect(rows.first['server_name'], 'CUST-1');
    expect(rows.first['sync_status'], 'synced');
    expect(rows.first['customer_name'], 'ACME');
    expect(rows.first['age'], 10);

    final outboxRows = await db.query('outbox');
    expect(outboxRows, isEmpty, reason: 'clean row should not be enqueued');
  });

  test('migrates dirty row and enqueues an INSERT outbox', () async {
    await db.insert('documents', {
      'localId': 'uuid-2',
      'doctype': 'Customer',
      'serverId': null,
      'status': 'dirty',
      'modified': 1700000000,
      'dataJson': jsonEncode({'customer_name': 'NEW', 'age': 5}),
    });

    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final parent = await db.query('docs__customer');
    expect(parent.first['sync_status'], 'dirty');
    final out = await db.query('outbox');
    expect(out.length, 1);
    expect(out.first['operation'], 'INSERT');
    expect(out.first['mobile_uuid'], 'uuid-2');
    expect(out.first['state'], 'pending');
  });

  test('dirty row WITH server_id enqueues UPDATE', () async {
    await db.insert('documents', {
      'localId': 'uuid-3',
      'doctype': 'Customer',
      'serverId': 'CUST-3',
      'status': 'dirty',
      'modified': 1700000000,
      'dataJson': jsonEncode({'customer_name': 'CHANGED', 'age': 7}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();
    final out = await db.query('outbox');
    expect(out.first['operation'], 'UPDATE');
    expect(out.first['server_name'], 'CUST-3');
  });

  test('deleted row enqueues DELETE', () async {
    await db.insert('documents', {
      'localId': 'uuid-4',
      'doctype': 'Customer',
      'serverId': 'CUST-4',
      'status': 'deleted',
      'modified': 1700000000,
      'dataJson': jsonEncode({'customer_name': 'X'}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();
    final out = await db.query('outbox');
    expect(out.first['operation'], 'DELETE');
  });

  test('order row with child table splits into parent + child rows', () async {
    final payload = {
      'customer': 'CUST-1',
      'items': [
        {'item_code': 'A', 'qty': 1},
        {'item_code': 'B', 'qty': 2},
      ],
    };
    await db.insert('documents', {
      'localId': 'uuid-order-1',
      'doctype': 'Sales Order',
      'serverId': 'SO-1',
      'status': 'clean',
      'modified': 1700000000,
      'dataJson': jsonEncode(payload),
    });

    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final parent = await db.query('docs__sales_order');
    expect(parent.length, 1);
    expect(parent.first['customer'], 'CUST-1');

    final children =
        await db.query('docs__sales_order_item', orderBy: 'idx ASC');
    expect(children.length, 2);
    expect(children[0]['idx'], 0);
    expect(children[0]['item_code'], 'A');
    expect(children[1]['item_code'], 'B');
    expect(children[0]['parent_uuid'], 'uuid-order-1');
  });

  test('row with unknown doctype meta goes to documents__orphaned_v1', () async {
    await db.insert('documents', {
      'localId': 'uuid-o',
      'doctype': 'Ghost',
      'serverId': 'G-1',
      'status': 'clean',
      'modified': 1700000000,
      'dataJson': '{}',
    });

    await V1ToV2Migration(db: db, metaFetcher: (dt) async {
      if (dt == 'Ghost') throw MetaNotFoundException(dt);
      return fakeMetaFetcher(dt);
    }).run();

    final orphan = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='documents__orphaned_v1'",
    );
    expect(orphan, isNotEmpty);
    final rows = await db.query('documents__orphaned_v1');
    expect(rows.length, 1);
  });

  test('row with corrupt JSON also orphaned, does not break the rest', () async {
    await db.insert('documents', {
      'localId': 'uuid-a',
      'doctype': 'Customer',
      'serverId': null,
      'status': 'dirty',
      'modified': 1,
      'dataJson': 'not valid {{{json',
    });
    await db.insert('documents', {
      'localId': 'uuid-b',
      'doctype': 'Customer',
      'serverId': null,
      'status': 'dirty',
      'modified': 2,
      'dataJson': jsonEncode({'customer_name': 'Ok'}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final rows = await db.query('docs__customer');
    expect(rows.length, 1);
    expect(rows.first['mobile_uuid'], 'uuid-b');
    final orphan = await db.query('documents__orphaned_v1');
    expect(orphan.length, 1);
  });

  test('sets sdk_meta.schema_version = 2 on successful completion', () async {
    await db.insert('documents', {
      'localId': 'x',
      'doctype': 'Customer',
      'serverId': null,
      'status': 'dirty',
      'modified': 1,
      'dataJson': jsonEncode({'customer_name': 'Y'}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();
    final row = await db.query('sdk_meta', limit: 1);
    expect(row.first['schema_version'], 2);
  });

  test('re-run is a no-op when schema_version=2', () async {
    await db.update('sdk_meta', {'schema_version': 2}, where: 'id=1');
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();
    final archived = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='documents__archived_v1'",
    );
    expect(archived, isEmpty);
  });

  test('dirty row with docstatus=1 enqueues UPDATE + SUBMIT', () async {
    await db.insert('documents', {
      'localId': 'uuid-sub',
      'doctype': 'Customer',
      'serverId': 'CUST-S',
      'status': 'dirty',
      'modified': 1700000000,
      'dataJson':
          jsonEncode({'customer_name': 'Sub', 'docstatus': 1}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final out = await db.query('outbox', orderBy: 'created_at ASC, id ASC');
    expect(out.length, 2);
    expect(out[0]['operation'], 'UPDATE');
    expect(out[1]['operation'], 'SUBMIT');
    expect(out[0]['mobile_uuid'], 'uuid-sub');
    expect(out[1]['mobile_uuid'], 'uuid-sub');
    // Both should be pending and target the same server name.
    expect(out[0]['state'], 'pending');
    expect(out[1]['state'], 'pending');
    expect(out[0]['server_name'], 'CUST-S');
    expect(out[1]['server_name'], 'CUST-S');
  });

  test('dirty row with docstatus=2 enqueues UPDATE + CANCEL', () async {
    await db.insert('documents', {
      'localId': 'uuid-can',
      'doctype': 'Customer',
      'serverId': 'CUST-C',
      'status': 'dirty',
      'modified': 1700000000,
      'dataJson':
          jsonEncode({'customer_name': 'Can', 'docstatus': 2}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final out = await db.query('outbox', orderBy: 'created_at ASC, id ASC');
    expect(out.length, 2);
    expect(out[0]['operation'], 'UPDATE');
    expect(out[1]['operation'], 'CANCEL');
  });

  test('dirty INSERT (no serverId) with docstatus=1 enqueues INSERT + SUBMIT', () async {
    await db.insert('documents', {
      'localId': 'uuid-ins-sub',
      'doctype': 'Customer',
      'serverId': null,
      'status': 'dirty',
      'modified': 1700000000,
      'dataJson':
          jsonEncode({'customer_name': 'New', 'docstatus': 1}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final out = await db.query('outbox', orderBy: 'created_at ASC, id ASC');
    expect(out.length, 2);
    expect(out[0]['operation'], 'INSERT');
    expect(out[1]['operation'], 'SUBMIT');
  });

  test('deleted row never gets a SUBMIT/CANCEL companion', () async {
    await db.insert('documents', {
      'localId': 'uuid-del',
      'doctype': 'Customer',
      'serverId': 'CUST-D',
      'status': 'deleted',
      'modified': 1700000000,
      'dataJson':
          jsonEncode({'customer_name': 'X', 'docstatus': 1}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();

    final out = await db.query('outbox');
    expect(out.length, 1);
    expect(out.first['operation'], 'DELETE');
  });

  test('renames documents to documents__archived_v1 on success', () async {
    await db.insert('documents', {
      'localId': 'x',
      'doctype': 'Customer',
      'serverId': null,
      'status': 'dirty',
      'modified': 1,
      'dataJson': jsonEncode({'customer_name': 'Y'}),
    });
    await V1ToV2Migration(db: db, metaFetcher: fakeMetaFetcher).run();
    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = tables.map((r) => r['name']).toSet();
    expect(names, contains('documents__archived_v1'));
    expect(names, isNot(contains('documents')));
  });
}
