import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/field_factory.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/link_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';

DocField _select(String fieldname) => DocField(
  fieldname: fieldname,
  fieldtype: 'Select',
  label: fieldname,
  options: 'Only',
);

DocField _link(String fieldname) => DocField(
  fieldname: fieldname,
  fieldtype: 'Link',
  label: fieldname,
  options: 'Some DocType',
);

void main() {
  group('FieldFactory threads the reserved-field decision into the widget', () {
    test('an ordinary Select is allowed to preselect', () {
      final f = FieldFactory()..doctype = 'Item Group';
      final w = f.createField(field: _select('status')) as SelectField;
      expect(w.allowPreselect, isTrue);
    });

    test('naming_series is not', () {
      final f = FieldFactory()..doctype = 'Item Group';
      final w = f.createField(field: _select('naming_series')) as SelectField;
      expect(w.allowPreselect, isFalse);
    });

    test('amended_from is not', () {
      final f = FieldFactory()..doctype = 'Item Group';
      final w =
          f.createField(field: _link('amended_from'), linkOptions: ['X'])
              as LinkField;
      expect(w.allowPreselect, isFalse);
    });

    test('auto_repeat is not', () {
      final f = FieldFactory()..doctype = 'Item Group';
      final w =
          f.createField(field: _link('auto_repeat'), linkOptions: ['X'])
              as LinkField;
      expect(w.allowPreselect, isFalse);
    });

    test('the nestedset parent Link of THIS doctype is not', () {
      final f = FieldFactory()..doctype = 'Item Group';
      final w =
          f.createField(field: _link('parent_item_group'), linkOptions: ['X'])
              as LinkField;
      expect(w.allowPreselect, isFalse);
    });

    test('a parent_* Link of a DIFFERENT doctype is allowed', () {
      final f = FieldFactory()..doctype = 'Sales Order';
      final w =
          f.createField(field: _link('parent_item_group'), linkOptions: ['X'])
              as LinkField;
      expect(w.allowPreselect, isTrue);
    });

    test('with no doctype set, only the fixed reserved names are caught', () {
      final f = FieldFactory();
      expect(
        (f.createField(field: _select('naming_series')) as SelectField)
            .allowPreselect,
        isFalse,
      );
      expect(
        (f.createField(field: _link('parent_item_group'), linkOptions: ['X'])
                as LinkField)
            .allowPreselect,
        isTrue,
      );
    });
  });
}
