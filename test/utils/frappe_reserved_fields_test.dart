import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/frappe_reserved_fields.dart';

void main() {
  group('frappeScrub', () {
    // Mirrors frappe/utils/data.py:
    //   return cstr(txt).replace(" ", "_").replace("-", "_").lower()
    test('replaces spaces and hyphens with underscore and lowercases', () {
      expect(frappeScrub('Sales Order'), 'sales_order');
      expect(frappeScrub('Cost-Center'), 'cost_center');
      expect(frappeScrub('Parent Item Group'), 'parent_item_group');
    });

    test(
      'leaves other punctuation intact, unlike the table-name normalizer',
      () {
        // normalizeDoctypeTableName() collapses "'" to "_"; frappe.scrub does
        // not. The nestedset parent fieldname follows frappe.scrub.
        expect(frappeScrub("Item's Group"), "item's_group");
      },
    );

    test('does not collapse repeated separators', () {
      expect(frappeScrub('A  B'), 'a__b');
    });
  });

  group('isFrappeReservedField', () {
    test('flags the std_fields pseudo-docfields', () {
      expect(isFrappeReservedField('name'), isTrue);
      expect(isFrappeReservedField('owner'), isTrue);
      expect(isFrappeReservedField('modified_by'), isTrue);
    });

    test('flags the conditional real DocFields', () {
      expect(isFrappeReservedField('amended_from'), isTrue);
      expect(isFrappeReservedField('old_parent'), isTrue);
      expect(isFrappeReservedField('auto_repeat'), isTrue);
    });

    test('flags naming_series', () {
      expect(isFrappeReservedField('naming_series'), isTrue);
    });

    test('flags the nestedset parent field for the given doctype', () {
      expect(
        isFrappeReservedField('parent_item_group', doctype: 'Item Group'),
        isTrue,
      );
      expect(
        isFrappeReservedField('parent_cost_center', doctype: 'Cost-Center'),
        isTrue,
      );
    });

    test('does not flag the nestedset parent field of a DIFFERENT doctype', () {
      expect(
        isFrappeReservedField('parent_item_group', doctype: 'Sales Order'),
        isFalse,
      );
    });

    test('does not flag the nestedset parent field with no doctype given', () {
      expect(isFrappeReservedField('parent_item_group'), isFalse);
    });

    test('does not flag ordinary fieldnames', () {
      expect(isFrappeReservedField('status'), isFalse);
      expect(isFrappeReservedField('customer'), isFalse);
      expect(isFrappeReservedField('parent_company'), isFalse);
    });

    test('does not flag null or empty', () {
      expect(isFrappeReservedField(null), isFalse);
      expect(isFrappeReservedField(''), isFalse);
    });
  });
}
