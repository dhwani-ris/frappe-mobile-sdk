import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

DocField f(String n, String t, {bool isVirtual = false}) =>
    DocField(fieldname: n, fieldtype: t, label: n, isVirtual: isVirtual);

void main() {
  group('listableFieldnamesForStar', () {
    test('excludes Image (no DB column) and layout/child fieldtypes', () {
      final meta = DocTypeMeta(
        name: 'X',
        fields: [
          f('customer_name', 'Data'),
          f('photo', 'Image'),
          f('sec', 'Section Break'),
          f('items', 'Table'),
          f('tags', 'Table MultiSelect'),
          f('logo', 'Image'),
        ],
      );
      final cols = listableFieldnamesForStar(meta);

      // Real data column kept.
      expect(cols, contains('customer_name'));
      // Image fieldnames must NOT be emitted — they have no get_list column.
      expect(cols, isNot(contains('photo')));
      expect(cols, isNot(contains('logo')));
      // Layout + child fieldtypes stay excluded.
      expect(cols, isNot(contains('sec')));
      expect(cols, isNot(contains('items')));
      expect(cols, isNot(contains('tags')));
      // Standard document columns are always present.
      expect(
        cols,
        containsAll(<String>[
          'name',
          'owner',
          'creation',
          'modified',
          'docstatus',
        ]),
      );
    });

    test('excludes virtual fields regardless of fieldtype', () {
      final meta = DocTypeMeta(
        name: 'X',
        fields: [
          // Same fieldtype, differing ONLY in is_virtual — pins that the skip
          // is driven by the flag, not by the fieldtype set.
          f('real_total', 'Currency'),
          f('virtual_total', 'Currency', isVirtual: true),
          f('virtual_note', 'Data', isVirtual: true),
          f('virtual_link', 'Link', isVirtual: true),
        ],
      );
      final cols = listableFieldnamesForStar(meta);

      // Virtual fields have no DB column — never emit them.
      expect(cols, isNot(contains('virtual_total')));
      expect(cols, isNot(contains('virtual_note')));
      expect(cols, isNot(contains('virtual_link')));
      // A non-virtual field of the SAME fieldtype is still emitted.
      expect(cols, contains('real_total'));
      // Standard document columns are unaffected.
      expect(cols, containsAll(<String>['name', 'owner', 'modified']));
    });

    test('is_virtual survives a DocTypeMeta JSON round-trip', () {
      // MetaService persists DocTypeMeta.toJson() into the local meta cache;
      // if the flag were dropped there, the virtual column would come back on
      // the next cold start.
      final meta = DocTypeMeta(
        name: 'X',
        fields: [
          f('real_total', 'Currency'),
          f('virtual_total', 'Currency', isVirtual: true),
        ],
      );
      final cols = listableFieldnamesForStar(
        DocTypeMeta.fromJson(meta.toJson()),
      );

      expect(cols, isNot(contains('virtual_total')));
      expect(cols, contains('real_total'));
    });
  });
}
