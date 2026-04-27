import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocField f(String name, String type) =>
    DocField(fieldname: name, fieldtype: type, label: name);

void main() {
  group('buildParentSchemaDDL', () {
    test('creates table with system columns', () {
      final meta = DocTypeMeta(name: 'Simple', fields: const []);
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__simple');
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      expect(createStmt, contains('mobile_uuid TEXT PRIMARY KEY'));
      expect(createStmt, contains('server_name TEXT'));
      expect(createStmt, contains("sync_status TEXT NOT NULL DEFAULT 'dirty'"));
      expect(createStmt, contains('sync_error TEXT'));
      expect(createStmt, contains('sync_attempts INTEGER NOT NULL DEFAULT 0'));
      expect(createStmt, contains('sync_op TEXT'));
      expect(createStmt, contains('docstatus INTEGER NOT NULL DEFAULT 0'));
      expect(createStmt, contains('modified TEXT'));
      expect(createStmt, contains('local_modified INTEGER NOT NULL'));
      expect(createStmt, contains('pulled_at INTEGER'));
    });

    test('adds one column per non-layout field', () {
      final meta = DocTypeMeta(
        name: 'Customer',
        fields: [
          f('customer_name', 'Data'),
          f('customer_age', 'Int'),
          f('is_active', 'Check'),
          f('notes', 'Long Text'),
          f('break1', 'Section Break'),
        ],
      );
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__customer');
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      expect(createStmt, contains('customer_name TEXT'));
      expect(createStmt, contains('customer_age INTEGER'));
      expect(createStmt, contains('is_active INTEGER'));
      expect(createStmt, contains('notes TEXT'));
      expect(createStmt, isNot(contains('break1')));
    });

    test('adds __is_local for Link fields', () {
      final meta = DocTypeMeta(
        name: 'Invoice',
        fields: [f('customer', 'Link'), f('dyn_ref', 'Dynamic Link')],
      );
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__invoice');
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      expect(createStmt, contains('customer TEXT'));
      expect(createStmt, contains('customer__is_local INTEGER'));
      expect(createStmt, contains('dyn_ref TEXT'));
      expect(createStmt, contains('dyn_ref__is_local INTEGER'));
    });

    test('adds __norm for search-target text fields', () {
      final meta = DocTypeMeta(
        name: 'Contact',
        titleField: 'full_name',
        searchFields: ['email_id'],
        fields: [
          f('full_name', 'Data'),
          f('email_id', 'Data'),
          f('age', 'Int'),
        ],
      );
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__contact');
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      expect(createStmt, contains('full_name__norm TEXT'));
      expect(createStmt, contains('email_id__norm TEXT'));
      expect(createStmt, isNot(contains('age__norm')));
    });

    test('skips Table / Table MultiSelect fields', () {
      final meta = DocTypeMeta(
        name: 'Order',
        fields: [f('items', 'Table'), f('taxes', 'Table MultiSelect')],
      );
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__order');
      final createStmt = ddl.firstWhere((s) => s.startsWith('CREATE TABLE'));
      // Match `items ` or `taxes ` followed by a column type — should NOT appear.
      expect(createStmt, isNot(matches(RegExp(r'\bitems\s+(TEXT|INTEGER|REAL)'))));
      expect(createStmt, isNot(matches(RegExp(r'\btaxes\s+(TEXT|INTEGER|REAL)'))));
    });

    test('emits UNIQUE partial index on server_name', () {
      final meta = DocTypeMeta(name: 'X', fields: const []);
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__x');
      expect(
        ddl.any((s) =>
            s.contains('UNIQUE INDEX') &&
            s.contains('server_name') &&
            s.contains('WHERE server_name IS NOT NULL')),
        isTrue,
      );
    });

    test('emits indexes on status/modified plus policy-chosen columns', () {
      final meta = DocTypeMeta(name: 'X', fields: const []);
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__x');
      expect(
        ddl.any((s) =>
            s.contains('CREATE INDEX') && s.contains('sync_status')),
        isTrue,
      );
      expect(
        ddl.any((s) =>
            s.contains('CREATE INDEX') && s.contains('modified')),
        isTrue,
      );
    });

    test('meta field colliding with system column is dropped (no duplicate)',
        () {
      // Consumers often add `mobile_uuid` for L2 idempotency; some
      // doctypes also expose `modified` / `docstatus` as fields. Without
      // dedup, SQLite rejects the CREATE TABLE.
      final meta = DocTypeMeta(name: 'Gram Panchayat', fields: [
        DocField(fieldname: 'mobile_uuid', fieldtype: 'Data', label: 'UUID'),
        DocField(fieldname: 'modified', fieldtype: 'Datetime', label: 'Mod'),
        DocField(fieldname: 'docstatus', fieldtype: 'Int', label: 'Stat'),
        DocField(
            fieldname: 'panchayat_name', fieldtype: 'Data', label: 'Name'),
      ]);
      final ddl = buildParentSchemaDDL(meta, tableName: 'docs__gp');
      final create = ddl.first;
      // Each system column should appear exactly once.
      for (final col in const [
        'mobile_uuid',
        'modified',
        'docstatus',
      ]) {
        final regex = RegExp('\\b$col\\b');
        final occurrences = regex.allMatches(create).length;
        expect(occurrences, 1,
            reason: '$col must appear once, found $occurrences');
      }
      // Real meta-only field still made it through.
      expect(create, contains('panchayat_name'));
    });

    test('duplicate field names in meta itself are deduped', () {
      final meta = DocTypeMeta(name: 'Y', fields: [
        DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
        DocField(fieldname: 'a', fieldtype: 'Data', label: 'A again'),
      ]);
      final create = buildParentSchemaDDL(meta, tableName: 'docs__y').first;
      expect(RegExp(r'\ba\s+TEXT\b').allMatches(create).length, 1);
    });
  });
}
