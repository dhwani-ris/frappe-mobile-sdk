import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/meta_differ.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

DocTypeMeta meta({
  String name = 'Customer',
  List<DocField> fields = const [],
  String? titleField,
  List<String>? searchFields,
}) =>
    DocTypeMeta(
      name: name,
      fields: fields,
      titleField: titleField,
      searchFields: searchFields,
    );

void main() {
  group('MetaDiffer.diff', () {
    test('no changes → noop', () {
      final a = meta(fields: [f('age', 'Int')]);
      final b = meta(fields: [f('age', 'Int')]);
      final d = MetaDiffer.diff(oldMeta: a, newMeta: b);
      expect(d.isNoOp, isTrue);
    });

    test('added field', () {
      final a = meta(fields: [f('age', 'Int')]);
      final b = meta(fields: [f('age', 'Int'), f('email', 'Data')]);
      final d = MetaDiffer.diff(oldMeta: a, newMeta: b);
      expect(d.addedFields.length, 1);
      expect(d.addedFields.first.name, 'email');
      expect(d.addedFields.first.sqlType, 'TEXT');
    });

    test('added Link field also adds __is_local column', () {
      final a = meta(fields: const []);
      final b = meta(fields: [f('customer', 'Link', options: 'Customer')]);
      final d = MetaDiffer.diff(oldMeta: a, newMeta: b);
      expect(d.addedFields.any((x) => x.name == 'customer'), isTrue);
      expect(d.addedIsLocalFor, contains('customer'));
    });

    test('added field that is in searchFields → __norm + backfill', () {
      final a = meta(fields: const [], searchFields: null);
      final b = meta(
        fields: [f('email', 'Data')],
        searchFields: ['email'],
      );
      final d = MetaDiffer.diff(oldMeta: a, newMeta: b);
      expect(d.addedNormFor, contains('email'));
    });

    test('removed field → indexesToDrop references its index name', () {
      final a = meta(fields: [f('legacy', 'Data')]);
      final b = meta(fields: const []);
      final d = MetaDiffer.diff(oldMeta: a, newMeta: b);
      expect(d.removedFields, contains('legacy'));
      expect(d.indexesToDrop, isNotEmpty);
    });

    test('type changed — no DDL addition, recorded for audit only', () {
      final a = meta(fields: [f('code', 'Data')]);
      final b = meta(fields: [f('code', 'Int')]);
      final d = MetaDiffer.diff(oldMeta: a, newMeta: b);
      expect(d.typeChanged, contains('code'));
      expect(d.addedFields, isEmpty);
      expect(d.removedFields, isEmpty);
    });

    test('layout fieldtypes ignored', () {
      final a = meta(fields: [f('break1', 'Section Break')]);
      final b = meta(fields: [f('break2', 'Section Break')]);
      final d = MetaDiffer.diff(oldMeta: a, newMeta: b);
      expect(d.isNoOp, isTrue);
    });
  });
}
