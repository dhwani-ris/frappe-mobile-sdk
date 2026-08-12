import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/field_type_mapping.dart';

void main() {
  group('sqliteColumnTypeFor', () {
    test('TEXT types', () {
      for (final t in [
        'Data',
        'Small Text',
        'Long Text',
        'Text',
        'Code',
        'HTML',
        'JSON',
        'Read Only',
        'Color',
        'Select',
        'Barcode',
        'Link',
        'Dynamic Link',
        'Attach',
        'Attach Image',
        'Signature',
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

    // Frappe persists a Rating as a 0..1 fraction (stars / max_stars), so
    // values like 0.6 are the norm — REAL, not INTEGER. The old expectation
    // ("numeric 1-5") encoded a star-count assumption Frappe does not use.
    test('Rating — REAL (Frappe stores a 0..1 fraction, e.g. 0.6)', () {
      expect(sqliteColumnTypeFor('Rating'), 'REAL');
    });

    test('layout fieldtypes have no column', () {
      for (final t in [
        'Section Break',
        'Column Break',
        'Tab Break',
        'Heading',
        'Button',
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

    test('Password fieldtype maps to no column (security: never persist)', () {
      // Password values would land in unencrypted SQLite if mapped to
      // any column type — exposing them on rooted/extracted devices.
      // The single source of truth is null mapping; PullApply, schema
      // generation, and push payload assembly all key off `== null`.
      expect(sqliteColumnTypeFor('Password'), isNull);
    });
  });
}
