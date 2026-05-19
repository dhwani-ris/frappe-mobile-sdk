import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/child_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ChildDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    final meta = DocTypeMeta(
      name: 'Order Item',
      fields: [
        DocField(fieldname: 'item_code', fieldtype: 'Data', label: 'I'),
        DocField(fieldname: 'qty', fieldtype: 'Int', label: 'Q'),
      ],
    );
    for (final stmt in buildChildSchemaDDL(meta, tableName: 'docs__order_item')) {
      await db.execute(stmt);
    }
    dao = ChildDao(db, tableName: 'docs__order_item');
  });

  tearDown(() async => db.close());

  test('insert + listByParent ordered by idx', () async {
    await dao.insert({
      'parent_uuid': 'P', 'parent_doctype': 'Order',
      'parentfield': 'items', 'idx': 2, 'item_code': 'B', 'qty': 2,
    });
    await dao.insert({
      'parent_uuid': 'P', 'parent_doctype': 'Order',
      'parentfield': 'items', 'idx': 1, 'item_code': 'A', 'qty': 1,
    });
    final rows = await dao.listByParent('P', 'items');
    expect(rows.map((r) => r['idx']).toList(), [1, 2]);
  });

  test('deleteByParent removes all children for parent+field', () async {
    await dao.insert({
      'parent_uuid': 'P1', 'parent_doctype': 'O',
      'parentfield': 'items', 'idx': 1, 'item_code': 'A',
    });
    await dao.insert({
      'parent_uuid': 'P2', 'parent_doctype': 'O',
      'parentfield': 'items', 'idx': 1, 'item_code': 'X',
    });
    final n = await dao.deleteByParent('P1', 'items');
    expect(n, 1);
    expect((await dao.listByParent('P2', 'items')).length, 1);
  });

  test('transactional replace: delete + insert new rows', () async {
    await dao.insert({
      'parent_uuid': 'P', 'parent_doctype': 'O',
      'parentfield': 'items', 'idx': 1, 'item_code': 'Old',
    });
    await db.transaction((txn) async {
      final tdao = ChildDao(txn, tableName: 'docs__order_item');
      await tdao.deleteByParent('P', 'items');
      await tdao.insert({
        'parent_uuid': 'P', 'parent_doctype': 'O',
        'parentfield': 'items', 'idx': 1, 'item_code': 'New',
      });
    });
    final rows = await dao.listByParent('P', 'items');
    expect(rows.length, 1);
    expect(rows.first['item_code'], 'New');
  });
}
