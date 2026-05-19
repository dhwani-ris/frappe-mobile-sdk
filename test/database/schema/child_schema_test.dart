import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocField f(String name, String type) =>
    DocField(fieldname: name, fieldtype: type, label: name);

void main() {
  group('buildChildSchemaDDL', () {
    test('creates table with child FK system columns', () {
      final meta = DocTypeMeta(name: 'Order Item', fields: const []);
      final ddl =
          buildChildSchemaDDL(meta, tableName: 'docs__order_item');
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      expect(createStmt, contains('mobile_uuid TEXT PRIMARY KEY'));
      expect(createStmt, contains('server_name TEXT'));
      expect(createStmt, contains('parent_uuid TEXT NOT NULL'));
      expect(createStmt, contains('parent_doctype TEXT NOT NULL'));
      expect(createStmt, contains('parentfield TEXT NOT NULL'));
      expect(createStmt, contains('idx INTEGER NOT NULL'));
      expect(createStmt, contains('modified TEXT'));
      expect(createStmt, isNot(contains('sync_status')));
    });

    test('adds child-specific field columns', () {
      final meta = DocTypeMeta(
        name: 'Order Item',
        fields: [
          f('item_code', 'Data'),
          f('qty', 'Int'),
          f('rate', 'Currency'),
        ],
      );
      final ddl =
          buildChildSchemaDDL(meta, tableName: 'docs__order_item');
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      expect(createStmt, contains('item_code TEXT'));
      expect(createStmt, contains('qty INTEGER'));
      expect(createStmt, contains('rate REAL'));
    });

    test('emits unique partial index on server_name', () {
      final meta = DocTypeMeta(name: 'C', fields: const []);
      final ddl = buildChildSchemaDDL(meta, tableName: 'docs__c');
      expect(
        ddl.any((s) => s.contains('UNIQUE INDEX') &&
            s.contains('server_name') &&
            s.contains('WHERE server_name IS NOT NULL')),
        isTrue,
      );
    });

    test('emits unique composite index on (parent_uuid, parentfield, idx)', () {
      final meta = DocTypeMeta(name: 'C', fields: const []);
      final ddl = buildChildSchemaDDL(meta, tableName: 'docs__c');
      expect(
        ddl.any((s) => s.contains('UNIQUE INDEX') &&
            s.contains('parent_uuid') &&
            s.contains('parentfield') &&
            s.contains('idx')),
        isTrue,
      );
    });
  });
}
