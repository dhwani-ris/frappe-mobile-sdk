import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/response_writeback.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
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
    final parentMeta = DocTypeMeta(
      name: 'Sales Order',
      fields: [f('items', 'Table', options: 'SO Item')],
    );
    final childMeta = DocTypeMeta(
      name: 'SO Item',
      isTable: true,
      fields: [f('qty', 'Int')],
    );
    for (final s in buildParentSchemaDDL(parentMeta, tableName: 'docs__sales_order')) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(childMeta, tableName: 'docs__so_item')) {
      await db.execute(s);
    }

    outbox = OutboxDao(db);
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u-so',
      'sync_status': 'dirty',
      'local_modified': 1,
    });
    await db.insert('docs__so_item', {
      'mobile_uuid': 'c-1',
      'parent_uuid': 'u-so',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 0,
      'qty': 2,
    });
    await outbox.insertPending(
      doctype: 'Sales Order',
      mobileUuid: 'u-so',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
  });

  tearDown(() async => db.close());

  test('writes parent server_name + modified, marks synced', () async {
    final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
    await ResponseWriteback.apply(
      db: db,
      row: outboxRow,
      parentTable: 'docs__sales_order',
      childTablesByFieldname: const {'items': 'docs__so_item'},
      response: {
        'name': 'SO-1001',
        'modified': '2026-02-01 10:00:00',
        'items': [
          {'name': 'SOIT-1', 'idx': 0, 'modified': '2026-02-01 10:00:00'},
        ],
      },
    );
    final p = (await db.query('docs__sales_order')).first;
    expect(p['server_name'], 'SO-1001');
    expect(p['modified'], '2026-02-01 10:00:00');
    expect(p['sync_status'], 'synced');
    final c = (await db.query('docs__so_item')).first;
    expect(c['server_name'], 'SOIT-1');
  });

  test('marks outbox row done with server_name', () async {
    final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
    await ResponseWriteback.apply(
      db: db,
      row: outboxRow,
      parentTable: 'docs__sales_order',
      childTablesByFieldname: const {},
      response: {'name': 'SO-1001', 'modified': '2026-02-01'},
    );
    final rows = await outbox.findByState(OutboxState.done);
    expect(rows.first.serverName, 'SO-1001');
  });

  test('matches children by (parent_uuid, parentfield, idx)', () async {
    await db.insert('docs__so_item', {
      'mobile_uuid': 'c-2',
      'parent_uuid': 'u-so',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 1,
      'qty': 5,
    });
    final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
    await ResponseWriteback.apply(
      db: db,
      row: outboxRow,
      parentTable: 'docs__sales_order',
      childTablesByFieldname: const {'items': 'docs__so_item'},
      response: {
        'name': 'SO',
        'modified': '2026-02-01',
        'items': [
          {'name': 'A', 'idx': 0, 'modified': '2026-02-01'},
          {'name': 'B', 'idx': 1, 'modified': '2026-02-01'},
        ],
      },
    );
    final rows = await db.query('docs__so_item', orderBy: 'idx ASC');
    expect(rows[0]['server_name'], 'A');
    expect(rows[1]['server_name'], 'B');
  });
}
