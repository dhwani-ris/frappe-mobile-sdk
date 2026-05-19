import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/frappe_document.dart';

void main() {
  group('standard accessors', () {
    test('name/doctype/owner default to empty string when missing', () {
      final d = FrappeDocument({});
      expect(d.name, '');
      expect(d.doctype, '');
      expect(d.owner, '');
    });

    test('name/doctype/owner read from data map', () {
      final d = FrappeDocument({
        'name': 'CUST-1',
        'doctype': 'Customer',
        'owner': 'alice@example.com',
      });
      expect(d.name, 'CUST-1');
      expect(d.doctype, 'Customer');
      expect(d.owner, 'alice@example.com');
    });

    test('name stringifies non-string values', () {
      expect(FrappeDocument({'name': 42}).name, '42');
    });

    test('creation/modified parse ISO 8601 strings', () {
      final d = FrappeDocument({
        'creation': '2026-05-18T10:30:00',
        'modified': '2026-05-18T11:00:00',
      });
      expect(d.creation, DateTime.parse('2026-05-18T10:30:00'));
      expect(d.modified, DateTime.parse('2026-05-18T11:00:00'));
    });

    test('creation/modified return null on invalid strings', () {
      expect(FrappeDocument({}).creation, isNull);
      expect(FrappeDocument({'creation': 'garbage'}).creation, isNull);
    });

    test('docstatus defaults to 0', () {
      expect(FrappeDocument({}).docstatus, 0);
    });

    test('docstatus parses int and string forms', () {
      expect(FrappeDocument({'docstatus': 1}).docstatus, 1);
      expect(FrappeDocument({'docstatus': '2'}).docstatus, 2);
      expect(FrappeDocument({'docstatus': 'bogus'}).docstatus, 0);
    });
  });

  group('typed getters', () {
    test('get<T> returns typed value', () {
      final d = FrappeDocument({'qty': 10, 'name': 'CUST-1'});
      expect(d.get<int>('qty'), 10);
      expect(d.get<String>('name'), 'CUST-1');
    });

    test('get<T> returns null for missing key', () {
      expect(FrappeDocument({}).get<int>('qty'), isNull);
    });

    test('getString stringifies any value', () {
      final d = FrappeDocument({'a': 'hi', 'b': 42, 'c': true});
      expect(d.getString('a'), 'hi');
      expect(d.getString('b'), '42');
      expect(d.getString('c'), 'true');
      expect(d.getString('missing'), '');
    });

    test('getDouble coerces num and parseable strings', () {
      final d = FrappeDocument({
        'a': 1.5,
        'b': 2,
        'c': '3.25',
        'd': 'nope',
        'e': null,
      });
      expect(d.getDouble('a'), 1.5);
      expect(d.getDouble('b'), 2.0);
      expect(d.getDouble('c'), 3.25);
      expect(d.getDouble('d'), 0.0);
      expect(d.getDouble('e'), 0.0);
      expect(d.getDouble('missing'), 0.0);
    });

    test('getInt coerces num and parseable strings', () {
      final d = FrappeDocument({'a': 1.9, 'b': 2, 'c': '3', 'd': 'nope'});
      expect(d.getInt('a'), 1, reason: 'toInt truncates toward zero');
      expect(d.getInt('b'), 2);
      expect(d.getInt('c'), 3);
      expect(d.getInt('d'), 0);
      expect(d.getInt('missing'), 0);
    });

    test('getBool maps bool, 1/0, "1"/"true" → true; else false', () {
      final d = FrappeDocument({
        'a': true,
        'b': false,
        'c': 1,
        'd': 0,
        'e': '1',
        'f': 'true',
        'g': 'True',
        'h': '0',
        'i': 'false',
        'j': 'yes',
        'k': null,
      });
      expect(d.getBool('a'), isTrue);
      expect(d.getBool('b'), isFalse);
      expect(d.getBool('c'), isTrue);
      expect(d.getBool('d'), isFalse);
      expect(d.getBool('e'), isTrue);
      expect(d.getBool('f'), isTrue);
      expect(d.getBool('g'), isTrue, reason: 'case-insensitive');
      expect(d.getBool('h'), isFalse);
      expect(d.getBool('i'), isFalse);
      expect(d.getBool('j'), isFalse);
      expect(d.getBool('k'), isFalse);
      expect(d.getBool('missing'), isFalse);
    });
  });

  group('toMap / toString', () {
    test('toMap returns the underlying map', () {
      final source = {'a': 1};
      final d = FrappeDocument(source);
      expect(
        identical(d.toMap(), source),
        isTrue,
        reason: 'toMap is intentionally a reference, not a copy',
      );
    });

    test('toString delegates to data map', () {
      expect(FrappeDocument({'a': 1}).toString(), '{a: 1}');
    });
  });
}
