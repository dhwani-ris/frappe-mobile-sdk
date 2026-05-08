import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(appDb);
    final meta = DocTypeMeta(
      name: 'Customer',
      titleField: 'customer_name',
      fields: [f('customer_name', 'Data'), f('code', 'Data')],
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Customer',
      jsonEncode(meta.toJson()),
    );
    // Pre-create the per-doctype table for Customer so applyServerDocument
    // can write into it. (Production: closure-pull would do this after
    // login.)
    for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
      await appDb.rawDatabase.execute(s);
    }
  });

  tearDown(() async {
    await appDb.rawDatabase.close();
  });

  test('applyServerDocument writes to docs__customer', () async {
    await repo.applyServerDocument(
      doctype: 'Customer',
      serverName: 'CUST-001',
      data: {
        'name': 'CUST-001',
        'customer_name': 'Acme Corp',
        'code': 'AC',
        'modified': '2026-01-01 00:00:00',
      },
    );

    final perDoctype = await appDb.rawDatabase.query(
      'docs__customer',
      limit: 10,
    );
    expect(perDoctype.length, 1);
    expect(perDoctype.first['server_name'], 'CUST-001');
    expect(perDoctype.first['customer_name'], 'Acme Corp');
    expect(perDoctype.first['code'], 'AC');
    expect(perDoctype.first['sync_status'], 'synced');
  });

  test(
    'second applyServerDocument with same name UPSERTs (no duplicate)',
    () async {
      await repo.applyServerDocument(
        doctype: 'Customer',
        serverName: 'CUST-001',
        data: {
          'name': 'CUST-001',
          'customer_name': 'Acme Corp',
          'modified': '2026-01-01 00:00:00',
        },
      );
      await repo.applyServerDocument(
        doctype: 'Customer',
        serverName: 'CUST-001',
        data: {
          'name': 'CUST-001',
          'customer_name': 'Acme Corp Updated',
          'modified': '2026-02-01 00:00:00',
        },
      );

      final rows = await appDb.rawDatabase.query('docs__customer');
      expect(rows.length, 1, reason: 'UPSERT, not insert-twice');
      expect(rows.first['customer_name'], 'Acme Corp Updated');
      expect(rows.first['modified'], '2026-02-01 00:00:00');
    },
  );

  test(
    'no meta persisted → applyServerDocument is a no-op (no table created)',
    () async {
      // No meta and no pre-built table for "NoMeta" — applyServerDocument
      // should silently skip rather than throw.
      await repo.applyServerDocument(
        doctype: 'NoMeta',
        serverName: 'NO-1',
        data: {'name': 'NO-1', 'foo': 'bar'},
      );
      final tables = await appDb.rawDatabase.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='docs__nometa'",
      );
      expect(tables, isEmpty);
    },
  );

  test('two different doctypes get two separate tables', () async {
    final supplierMeta = DocTypeMeta(
      name: 'Supplier',
      fields: [f('supplier_name', 'Data')],
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Supplier',
      jsonEncode(supplierMeta.toJson()),
    );
    for (final s in buildParentSchemaDDL(
      supplierMeta,
      tableName: 'docs__supplier',
    )) {
      await appDb.rawDatabase.execute(s);
    }

    await repo.applyServerDocument(
      doctype: 'Customer',
      serverName: 'C1',
      data: {'name': 'C1', 'customer_name': 'A'},
    );
    await repo.applyServerDocument(
      doctype: 'Supplier',
      serverName: 'S1',
      data: {'name': 'S1', 'supplier_name': 'B'},
    );

    expect((await appDb.rawDatabase.query('docs__customer')).length, 1);
    expect((await appDb.rawDatabase.query('docs__supplier')).length, 1);
  });

  group('ensureSchemaForClosure', () {
    test(
      'creates parent tables for every closure parent (even 0-row ones)',
      () async {
        final categoryMeta = DocTypeMeta(
          name: 'Category',
          fields: [f('category_name', 'Data')],
        );
        final tagMeta = DocTypeMeta(
          name: 'Tag',
          fields: [f('tag_name', 'Data')],
        );
        await repo.ensureSchemaForClosure(
          metas: {'Category': categoryMeta, 'Tag': tagMeta},
          childDoctypes: const {},
        );
        final tables = await appDb.rawDatabase.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name IN ('docs__category','docs__tag') ORDER BY name",
        );
        expect(tables.map((r) => r['name']).toList(), [
          'docs__category',
          'docs__tag',
        ]);
      },
    );

    test('creates child tables for closure children', () async {
      final itemMeta = DocTypeMeta(
        name: 'Order Item',
        isTable: true,
        fields: [f('item_name', 'Data'), f('qty', 'Int')],
      );
      await repo.ensureSchemaForClosure(
        metas: {'Order Item': itemMeta},
        childDoctypes: const {'Order Item'},
      );
      final tables = await appDb.rawDatabase.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name = 'docs__order_item'",
      );
      expect(tables, hasLength(1));
    });

    test(
      'applyServerDocument with child rows populates registered child table',
      () async {
        final orderMeta = DocTypeMeta(
          name: 'Order',
          fields: [
            f('title', 'Data'),
            f('items', 'Table', options: 'Order Item'),
          ],
        );
        final itemMeta = DocTypeMeta(
          name: 'Order Item',
          isTable: true,
          fields: [f('item_name', 'Data'), f('qty', 'Int')],
        );
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Order',
          jsonEncode(orderMeta.toJson()),
        );
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Order Item',
          jsonEncode(itemMeta.toJson()),
        );
        await repo.ensureSchemaForClosure(
          metas: {'Order': orderMeta, 'Order Item': itemMeta},
          childDoctypes: const {'Order Item'},
        );

        await repo.applyServerDocument(
          doctype: 'Order',
          serverName: 'ORD-1',
          data: {
            'name': 'ORD-1',
            'modified': '2026-01-01 00:00:00',
            'title': 'Sample Order',
            'items': [
              {'name': 'item-1', 'item_name': 'Widget', 'qty': 32},
              {'name': 'item-2', 'item_name': 'Gizmo', 'qty': 12},
            ],
          },
        );

        final children = await appDb.rawDatabase.query(
          'docs__order_item',
          orderBy: 'idx',
        );
        expect(children.length, 2);
        expect(children[0]['item_name'], 'Widget');
        expect(children[0]['parentfield'], 'items');
        expect(children[0]['parent_doctype'], 'Order');
        expect(children[1]['item_name'], 'Gizmo');
        expect(children[1]['idx'], 1);
      },
    );
  });
}
