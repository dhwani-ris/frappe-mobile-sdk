import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema_applier.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

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
    for (final stmt in doctypeMetaExtensionsDDL()) {
      await db.execute(stmt);
    }
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
  });

  tearDown(() async => db.close());

  test('creates parent table with auto-registered table_name', () async {
    final meta = DocTypeMeta(
      name: 'Sales Order',
      fields: [
        DocField(fieldname: 'customer', fieldtype: 'Link', label: 'Customer'),
      ],
    );
    await db.insert('doctype_meta',
        {'doctype': 'Sales Order', 'metaJson': '{}', 'isMobileForm': 0});
    await SchemaApplier.apply(db, meta, isChildTable: false);

    final tbls = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'docs__%'",
    );
    final tableNames = tbls.map((r) => r['name'] as String).toSet();
    expect(tableNames, contains('docs__sales_order'));

    final metaRow = await db.query('doctype_meta',
        where: 'doctype=?', whereArgs: ['Sales Order']);
    expect(metaRow.first['table_name'], 'docs__sales_order');
  });

  test('creates child table when isChildTable=true', () async {
    final meta = DocTypeMeta(
      name: 'Sales Order Item',
      fields: [
        DocField(fieldname: 'item_code', fieldtype: 'Data', label: 'Item'),
      ],
    );
    await db.insert('doctype_meta',
        {'doctype': 'Sales Order Item', 'metaJson': '{}', 'isMobileForm': 0});
    await SchemaApplier.apply(db, meta, isChildTable: true);

    final cols = await db.rawQuery('PRAGMA table_info(docs__sales_order_item)');
    final names = cols.map((r) => r['name'] as String).toSet();
    expect(names, contains('parent_uuid'));
    expect(names, contains('idx'));
  });

  test('apply is idempotent on re-run (skips existing tables)', () async {
    final meta = DocTypeMeta(name: 'X', fields: const []);
    await db.insert('doctype_meta', {'doctype': 'X', 'metaJson': '{}', 'isMobileForm': 0});
    await SchemaApplier.apply(db, meta, isChildTable: false);
    // Second run should not throw.
    await SchemaApplier.apply(db, meta, isChildTable: false);
  });
}
