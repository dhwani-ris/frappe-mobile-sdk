import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  group('extractErrorMessage', () {
    test('extracts message from _server_messages JSON with HTML link', () {
      final body = {
        '_server_messages':
            '[{"message": "<a href=\\"...\\">FRM-0001</a> already exists"}]',
      };

      final msg = extractErrorMessage(body);

      expect(msg, 'FRM-0001 already exists');
    });

    test('falls back to message field when no _server_messages', () {
      final body = {'message': 'Simple error message.'};

      final msg = extractErrorMessage(body);

      expect(msg, 'Simple error message.');
    });

    test('falls back to exception when present', () {
      final body = {
        'exception':
            'ValidationError: Customer Name is required\nTraceback (most recent call last): ...',
      };

      final msg = extractErrorMessage(body);

      expect(msg, contains('Customer Name is required'));
      expect(msg, isNot(contains('Traceback')));
    });

    test('returns string when body is not a map', () {
      final msg = extractErrorMessage('Something went wrong');
      expect(msg, 'Something went wrong');
    });

    test('returns Unknown Error when no known keys', () {
      final msg = extractErrorMessage(<String, dynamic>{'foo': 'bar'});
      expect(msg, 'Unknown Error');
    });
  });

  group('toUserFriendlyMessage', () {
    test('handles ValidationError text', () {
      final raw =
          'frappe.exceptions.ValidationError: Farmer Name is required\n'
          'Errors: ... Traceback (most recent call last): ...';

      final msg = toUserFriendlyMessage(raw);

      expect(msg, 'Farmer Name is required.');
    });

    test('handles LinkExistsError text', () {
      final raw =
          'frappe.exceptions.LinkExistsError: Customer CUST-0001 already exists\n'
          'Traceback (most recent call last): ...';

      final msg = toUserFriendlyMessage(raw);

      expect(msg, 'Customer CUST-0001 already exists.');
    });

    test('uses _server_messages when provided as map', () {
      final body = {
        '_server_messages':
            '[{"message": "Email already exists for another user"}]',
      };

      final msg = toUserFriendlyMessage(body);

      expect(msg, 'Email already exists for another user.');
    });

    test('truncates very long messages safely', () {
      final long = 'A' * 1000;
      final msg = toUserFriendlyMessage(long);

      expect(msg.length, lessThanOrEqualTo(250));
    });
  });
}
