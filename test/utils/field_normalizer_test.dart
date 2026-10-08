import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/constants/field_types.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/utils/date_helpers.dart';
import 'package:frappe_mobile_sdk/src/utils/field_normalizer.dart';

DocField _f(String type, {String? options, bool allowMultiple = false}) =>
    DocField(fieldtype: type, options: options, allowMultiple: allowMultiple);

void main() {
  group('normalize — date / datetime', () {
    test('null and empty string become null', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.date), ''), isNull);
      expect(FieldNormalizer.normalize(_f(FieldTypes.datetime), null), isNull);
    });
    test('DateTime passes through unchanged', () {
      final dt = DateTime(2026, 6, 8);
      expect(FieldNormalizer.normalize(_f(FieldTypes.date), dt), same(dt));
    });
    test('ISO string parses to DateTime', () {
      expect(
        FieldNormalizer.normalize(_f(FieldTypes.datetime), '2026-06-08 10:30'),
        DateTime.tryParse('2026-06-08 10:30'),
      );
    });
    test('unparseable string becomes null', () {
      expect(
        FieldNormalizer.normalize(_f(FieldTypes.date), 'not-a-date'),
        isNull,
      );
    });
  });

  group('normalize — time', () {
    test('HH:mm string maps to DateTime(2000,1,1,h,m)', () {
      expect(
        FieldNormalizer.normalize(_f(FieldTypes.time), '14:30'),
        DateTime(2000, 1, 1, 14, 30),
      );
    });
    test('TimeOfDay maps to DateTime(2000,1,1,h,m)', () {
      expect(
        FieldNormalizer.normalize(
          _f(FieldTypes.time),
          const TimeOfDay(hour: 9, minute: 5),
        ),
        DateTime(2000, 1, 1, 9, 5),
      );
    });
    test('malformed time becomes null', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.time), 'noon'), isNull);
    });
  });

  group('normalize — check (bool coercion)', () {
    test('bool passes through', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.check), true), isTrue);
    });
    test('int 1 is true, anything else false', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.check), 1), isTrue);
      expect(FieldNormalizer.normalize(_f(FieldTypes.check), 0), isFalse);
    });
    test('"1" and "true" (case-insensitive) are true, others false', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.check), 'TRUE'), isTrue);
      expect(FieldNormalizer.normalize(_f(FieldTypes.check), '1'), isTrue);
      expect(FieldNormalizer.normalize(_f(FieldTypes.check), 'no'), isFalse);
    });
    test('unrecognized type coerces to false', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.check), 3.5), isFalse);
    });
  });

  group('normalize — rating', () {
    test('null/empty becomes null', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.rating), ''), isNull);
    });
    test('int passes through; numeric string parses', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.rating), 4), 4);
      expect(FieldNormalizer.normalize(_f(FieldTypes.rating), '3'), 3);
    });
    test('a stored 0..1 fraction is kept, not dropped', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.rating), 0.6), 0.6);
      expect(FieldNormalizer.normalize(_f(FieldTypes.rating), 1.0), 1.0);
      expect(FieldNormalizer.normalize(_f(FieldTypes.rating), '0.6'), 0.6);
    });
    test('always yields a double, the type RatingField holds', () {
      expect(
        FieldNormalizer.normalize(_f(FieldTypes.rating), 4),
        isA<double>(),
      );
      expect(
        FieldNormalizer.normalize(_f(FieldTypes.rating), 0.6),
        isA<double>(),
      );
    });
    test('a non-numeric value becomes null', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.rating), 'abc'), isNull);
    });
  });

  group('normalize — select', () {
    test('no options returns toString (empty for null)', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.select), 'X'), 'X');
      expect(FieldNormalizer.normalize(_f(FieldTypes.select), null), '');
    });
    test('single select with options: string, or null when empty', () {
      final f = _f(FieldTypes.select, options: 'A\nB');
      expect(FieldNormalizer.normalize(f, 'A'), 'A');
      expect(FieldNormalizer.normalize(f, ''), isNull);
    });
    test('multi-select splits comma string and passes lists through', () {
      final f = _f(FieldTypes.select, options: 'A\nB', allowMultiple: true);
      expect(FieldNormalizer.normalize(f, 'A, B'), ['A', 'B']);
      expect(FieldNormalizer.normalize(f, ['A', 'B']), ['A', 'B']);
      expect(FieldNormalizer.normalize(f, null), <String>[]);
    });
  });

  group('normalize — text / link / numeric passthrough as string', () {
    test('text-like returns toString (null -> empty)', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.data), 'hi'), 'hi');
      expect(FieldNormalizer.normalize(_f(FieldTypes.link), null), '');
    });
    test('numeric fieldtypes return toString', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.int), 42), '42');
      expect(FieldNormalizer.normalize(_f(FieldTypes.currency), null), '');
    });
  });

  group('normalize — duration', () {
    test('null/empty returns empty string', () {
      expect(FieldNormalizer.normalize(_f(FieldTypes.duration), ''), '');
    });
    test('int seconds formatted; non-int returns toString', () {
      expect(
        FieldNormalizer.normalize(_f(FieldTypes.duration), 90),
        formatDurationSeconds(90),
      );
      expect(FieldNormalizer.normalize(_f(FieldTypes.duration), '1m'), '1m');
    });
  });

  group('normalize — Table / default', () {
    test('Table: list passes through, non-list becomes empty list', () {
      expect(FieldNormalizer.normalize(_f('Table'), [1, 2]), [1, 2]);
      expect(FieldNormalizer.normalize(_f('Table'), 'x'), <dynamic>[]);
    });
    test('unknown fieldtype passes the value through unchanged', () {
      final obj = Object();
      expect(
        FieldNormalizer.normalize(_f(FieldTypes.geolocation), obj),
        same(obj),
      );
    });
  });
}
