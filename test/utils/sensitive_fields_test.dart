import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/sensitive_fields.dart';

void main() {
  group('redactSensitiveFields', () {
    test('masks known credential keys and leaves other fields untouched', () {
      final redacted = redactSensitiveFields({
        'mobile_no': '9876543210',
        'otp': '123456',
        'pwd': 'hunter2',
        'password': 'hunter2',
        'access_token': 'AT-1',
        'refresh_token': 'RT-1',
        'api_key': 'k1',
        'api_secret': 's1',
        'client_secret': 'c1',
        'code_verifier': 'v1',
        'secret': 'x1',
        'doctype': 'Visit Log',
      });

      expect(redacted['mobile_no'], '9876543210');
      expect(redacted['doctype'], 'Visit Log');
      for (final key in sensitiveBodyFieldNames) {
        expect(redacted[key], '[REDACTED]', reason: '$key must be masked');
      }
    });

    test('matches sensitive keys case-insensitively', () {
      final redacted = redactSensitiveFields({'OTP': '123456', 'Pwd': 'x'});
      expect(redacted['OTP'], '[REDACTED]');
      expect(redacted['Pwd'], '[REDACTED]');
    });

    test('passes a non-Map body through unchanged', () {
      expect(redactSensitiveFields(null), isNull);
      expect(redactSensitiveFields('raw string'), 'raw string');
      expect(redactSensitiveFields([1, 2, 3]), [1, 2, 3]);
    });

    test('does not mutate the original map (the real body still needs the '
        'live credential to actually make the request)', () {
      final original = {'otp': '123456'};
      final redacted = redactSensitiveFields(original);
      expect(original['otp'], '123456');
      expect(redacted['otp'], '[REDACTED]');
    });
  });
}
