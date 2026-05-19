import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';

void main() {
  group('normalizeDoctypeTableName', () {
    test('lowercase + spaces to underscores', () {
      expect(normalizeDoctypeTableName('Sales Order'), 'docs__sales_order');
    });

    test('strips non-alphanumeric', () {
      expect(normalizeDoctypeTableName("Kid's Toy"), 'docs__kid_s_toy');
      expect(normalizeDoctypeTableName('DocType/Child'), 'docs__doctype_child');
    });

    test('collapses consecutive underscores', () {
      expect(normalizeDoctypeTableName('A  B'), 'docs__a_b');
      expect(normalizeDoctypeTableName('A - - B'), 'docs__a_b');
    });

    test('strips leading/trailing underscores from the doctype portion', () {
      expect(normalizeDoctypeTableName(' Leading '), 'docs__leading');
    });

    test('child-table variant', () {
      expect(
        normalizeDoctypeTableName('Education Detail', prefix: 'docs__'),
        'docs__education_detail',
      );
    });

    test('empty or whitespace-only raises', () {
      expect(() => normalizeDoctypeTableName(''), throwsArgumentError);
      expect(() => normalizeDoctypeTableName('   '), throwsArgumentError);
    });

    test('identical normalized form for different inputs can collide', () {
      expect(
        normalizeDoctypeTableName('A B'),
        normalizeDoctypeTableName('A  B'),
      );
    });
  });
}
