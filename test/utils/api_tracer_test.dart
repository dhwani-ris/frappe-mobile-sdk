import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frappe_mobile_sdk/src/utils/api_tracer.dart';

void main() {
  late List<String> printed;
  late DebugPrintCallback original;

  setUp(() {
    printed = <String>[];
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };
  });
  tearDown(() => debugPrint = original);

  test('a login request trace does not print the password', () {
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/mobile_auth.login',
      body: {'username': 'field@example.org', 'password': 'hunter2-secret'},
    );

    final out = printed.join('\n');
    expect(out, contains('mobile_auth.login'));
    expect(out, contains('field@example.org'));
    expect(out, isNot(contains('hunter2-secret')));
  });

  test('OTP, refresh token and secrets are redacted at any depth', () {
    ApiTracer.traceRequest(
      method: 'POST',
      url: 'https://example.org/api/method/x',
      body: {
        'tmp_id': 'tmp-1',
        'otp': '493817',
        'nested': {'refresh_token': 'RT-live', 'api_secret': 'S-live'},
        'rows': [
          {'access_token': 'AT-live'},
        ],
      },
    );

    final out = printed.join('\n');
    expect(out, contains('tmp-1'));
    for (final secret in ['493817', 'RT-live', 'S-live', 'AT-live']) {
      expect(out, isNot(contains(secret)));
    }
  });

  test('credential query parameters are redacted in the URL and query', () {
    ApiTracer.traceRequest(
      method: 'GET',
      url: 'https://example.org/api/method/x?token=AT-live&page=2',
      queryParams: {'token': 'AT-live', 'page': 2},
    );
    ApiTracer.traceResponse(
      statusCode: 200,
      url: 'https://example.org/api/method/x?token=AT-live&page=2',
    );

    final out = printed.join('\n');
    expect(out, contains('page'));
    expect(out, isNot(contains('AT-live')));
  });
}
