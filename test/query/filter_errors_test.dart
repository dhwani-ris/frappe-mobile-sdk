import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/query/filter_errors.dart';

void main() {
  test('FilterParseError.toString includes class name and message', () {
    const e = FilterParseError('unknown operator >=');
    expect(e.toString(), 'FilterParseError: unknown operator >=');
    expect(e.message, 'unknown operator >=');
  });

  test('UnsupportedFilterError.toString includes class name and message', () {
    const e = UnsupportedFilterError('cross-doctype filters not supported');
    expect(
      e.toString(),
      'UnsupportedFilterError: cross-doctype filters not supported',
    );
    expect(e.message, 'cross-doctype filters not supported');
  });

  test('FilterParseError is an Exception', () {
    const e = FilterParseError('x');
    expect(e, isA<Exception>());
  });

  test('UnsupportedFilterError is an Exception', () {
    const e = UnsupportedFilterError('x');
    expect(e, isA<Exception>());
  });
}
