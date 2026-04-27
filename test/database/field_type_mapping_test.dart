import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/field_type_mapping.dart';

void main() {
  group('sqliteColumnTypeFor', () {
    test('TEXT types', () {
      for (final t in [
        'Data', 'Small Text', 'Long Text', 'Text', 'Code', 'HTML',
        'JSON', 'Read Only', 'Password', 'Color', 'Select', 'Barcode',
        'Link', 'Dynamic Link', 'Attach', 'Attach Image', 'Signature',
        'Geolocation',
      ]) {
        expect(sqliteColumnTypeFor(t), 'TEXT', reason: t);
      }
    });

    test('INTEGER types', () {
      for (final t in ['Int', 'Check', 'Duration']) {
        expect(sqliteColumnTypeFor(t), 'INTEGER', reason: t);
      }
    });

    test('REAL types', () {
      for (final t in ['Float', 'Currency', 'Percent']) {
        expect(sqliteColumnTypeFor(t), 'REAL', reason: t);
      }
    });

    test('Date/Datetime/Time as TEXT ISO8601', () {
      expect(sqliteColumnTypeFor('Date'), 'TEXT');
      expect(sqliteColumnTypeFor('Datetime'), 'TEXT');
      expect(sqliteColumnTypeFor('Time'), 'TEXT');
    });

    test('Rating — INTEGER (numeric 1-5)', () {
      expect(sqliteColumnTypeFor('Rating'), 'INTEGER');
    });

    test('layout fieldtypes have no column', () {
      for (final t in [
        'Section Break', 'Column Break', 'Tab Break',
        'Heading', 'Button',
      ]) {
        expect(sqliteColumnTypeFor(t), isNull, reason: t);
      }
    });

    test('Table and Table MultiSelect have no parent column', () {
      expect(sqliteColumnTypeFor('Table'), isNull);
      expect(sqliteColumnTypeFor('Table MultiSelect'), isNull);
    });

    test('unknown fieldtype defaults to TEXT (safe fallback)', () {
      expect(sqliteColumnTypeFor('FutureFieldType'), 'TEXT');
    });

    test('isLinkFieldType identifies Link-family', () {
      expect(isLinkFieldType('Link'), isTrue);
      expect(isLinkFieldType('Dynamic Link'), isTrue);
      expect(isLinkFieldType('Data'), isFalse);
    });

    test('isChildTableFieldType identifies Table-family', () {
      expect(isChildTableFieldType('Table'), isTrue);
      expect(isChildTableFieldType('Table MultiSelect'), isTrue);
      expect(isChildTableFieldType('Link'), isFalse);
    });
  });
}
