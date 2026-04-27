import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DocTypeMeta parentMeta;
  late DocTypeMeta childMeta;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    parentMeta = DocTypeMeta(
      name: 'Sales Order',
      titleField: 'customer',
      fields: [
        f('customer', 'Link', options: 'Customer'),
        f('items', 'Table', options: 'Sales Order Item'),
      ],
    );
    childMeta = DocTypeMeta(
      name: 'Sales Order Item',
      isTable: true,
      fields: [
        f('item_code', 'Data'),
        f('qty', 'Int'),
      ],
    );
    for (final s in buildParentSchemaDDL(parentMeta, tableName: 'docs__sales_order')) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(childMeta, tableName: 'docs__sales_order_item')) {
      await db.execute(s);
    }
  });

  tearDown(() async => db.close());

  test('UPSERT inserts new row with generated mobile_uuid', () async {
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: {
        'items': PullApplyChildInfo('Sales Order Item', childMeta),
      },
      rows: [
        {
          'name': 'SO-1',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-1',
          'items': [
            {'item_code': 'A', 'qty': 1},
          ],
        },
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.length, 1);
    expect(p.first['server_name'], 'SO-1');
    expect(p.first['mobile_uuid'], isNotNull);
    expect(p.first['sync_status'], 'synced');
    expect(p.first['customer'], 'CUST-1');
    final c = await db.query('docs__sales_order_item');
    expect(c.length, 1);
    expect(c.first['item_code'], 'A');
  });

  test('UPSERT updates existing, preserves mobile_uuid', () async {
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u1',
      'server_name': 'SO-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'customer': 'OLD',
    });
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: const {},
      rows: [
        {'name': 'SO-1', 'modified': '2026-01-02', 'customer': 'NEW'},
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.length, 1);
    expect(p.first['mobile_uuid'], 'u1');
    expect(p.first['customer'], 'NEW');
  });

  test('marks conflict when local is dirty', () async {
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u1',
      'server_name': 'SO-1',
      'sync_status': 'dirty',
      'local_modified': 1,
      'customer': 'LOCAL_EDIT',
    });
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: const {},
      rows: [
        {'name': 'SO-1', 'modified': '2026-02-01', 'customer': 'SERVER_NEW'},
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.first['sync_status'], 'conflict');
    expect(p.first['customer'], 'LOCAL_EDIT',
        reason: 'local dirty payload preserved');
  });

  test('children fully replaced on re-pull', () async {
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u1',
      'server_name': 'SO-1',
      'sync_status': 'synced',
      'local_modified': 1,
    });
    await db.insert('docs__sales_order_item', {
      'mobile_uuid': 'c1',
      'parent_uuid': 'u1',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 0,
      'item_code': 'OLD-A',
      'qty': 1,
    });
    await db.insert('docs__sales_order_item', {
      'mobile_uuid': 'c2',
      'parent_uuid': 'u1',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 1,
      'item_code': 'OLD-B',
      'qty': 2,
    });

    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: {
        'items': PullApplyChildInfo('Sales Order Item', childMeta),
      },
      rows: [
        {
          'name': 'SO-1',
          'modified': '2026-02-01',
          'items': [
            {'item_code': 'NEW-X', 'qty': 9},
          ],
        },
      ],
    );
    final c = await db.query('docs__sales_order_item');
    expect(c.length, 1);
    expect(c.first['item_code'], 'NEW-X');
  });

  test('__norm populated on write for title_field + searchFields', () async {
    final m = DocTypeMeta(
      name: 'Customer',
      titleField: 'full_name',
      searchFields: ['email'],
      fields: [
        f('full_name', 'Data'),
        f('email', 'Data'),
      ],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await PullApply.applyPage(
      db: db,
      parentMeta: m,
      parentTable: 'docs__customer',
      childMetasByFieldname: const {},
      rows: [
        {
          'name': 'C-1',
          'modified': '2026-01-01',
          'full_name': 'Café Ankıt',
          'email': 'A@B.COM',
        },
      ],
    );
    final row = await db.query('docs__customer');
    expect(row.first['full_name__norm'], 'cafe ankit');
    expect(row.first['email__norm'], 'a@b.com');
  });

  test('Link fields receive __is_local=0 (server values)', () async {
    await PullApply.applyPage(
      db: db,
      parentMeta: parentMeta,
      parentTable: 'docs__sales_order',
      childMetasByFieldname: const {},
      rows: [
        {'name': 'SO-Z', 'modified': '2026-01-01', 'customer': 'CUST-Z'},
      ],
    );
    final p = await db.query('docs__sales_order');
    expect(p.first['customer__is_local'], 0);
  });

  // Regression: doctypes that expose `mobile_uuid` as a meta field (used for
  // L2 idempotency on the server) used to have their generated PK overwritten
  // by the server's empty string, causing all but the first row to fail
  // with `UNIQUE constraint failed: mobile_uuid` -- silently swallowed by the
  // best-effort catch in OfflineRepository._writeToPerDoctypeTable.
  test('meta-defined mobile_uuid does NOT overwrite generated PK', () async {
    final m = DocTypeMeta(
      name: 'Employee',
      fields: [
        f('emp_id', 'Data'),
        f('mobile_uuid', 'Data'),
        f('modified', 'Datetime'),
        f('docstatus', 'Int'),
      ],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__employee')) {
      await db.execute(s);
    }
    await PullApply.applyPage(
      db: db,
      parentMeta: m,
      parentTable: 'docs__employee',
      childMetasByFieldname: const {},
      rows: [
        // Three rows the server returns with empty/null mobile_uuid -- a
        // non-deduped write would PK-collide on the second one.
        {'name': 'EMP-1', 'modified': '2026-01-01', 'emp_id': 'E1', 'mobile_uuid': '', 'docstatus': 0},
        {'name': 'EMP-2', 'modified': '2026-01-02', 'emp_id': 'E2', 'mobile_uuid': '', 'docstatus': 1},
        {'name': 'EMP-3', 'modified': '2026-01-03', 'emp_id': 'E3', 'mobile_uuid': null, 'docstatus': 0},
      ],
    );
    final rows = await db.query('docs__employee', orderBy: 'server_name');
    expect(rows.length, 3, reason: 'all three rows must land');
    final uuids = rows.map((r) => r['mobile_uuid']).toSet();
    expect(uuids.length, 3, reason: 'each row needs a distinct generated UUID');
    for (final u in uuids) {
      expect(u, isA<String>());
      expect((u as String).isNotEmpty, isTrue);
    }
    // docstatus IS still mirrored from server data (system column with sane
    // default; meta-loop value passes through but does not break PK).
    expect(rows.firstWhere((r) => r['server_name'] == 'EMP-2')['docstatus'], 1);
  });
}
