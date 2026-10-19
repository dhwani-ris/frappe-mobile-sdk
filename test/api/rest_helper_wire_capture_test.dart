import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

void main() {
  RestHelper helperReturning(int status, {Map<String, String>? headers}) {
    final mock = MockClient(
      (req) async => http.Response(
        jsonEncode({
          'exc_type': 'ValidationError',
          '_server_messages': '["nope"]',
        }),
        status,
        headers: {'content-type': 'application/json', ...?headers},
      ),
    );
    return RestHelper('https://x.test', client: mock)..setBearerToken('tok');
  }

  test('417 ValidationException carries request + body + trace_id', () async {
    final h = helperReturning(
      417,
      headers: {'x-frappe-request-id': 'trace-417'},
    );
    try {
      await h.post('/api/resource/Foo', body: {'doctype': 'Foo', 'a': 1});
      fail('expected throw');
    } on ValidationException catch (e) {
      expect(e.requestUrl, 'https://x.test/api/resource/Foo');
      expect(e.requestMethod, 'POST');
      expect(e.requestBody, {'doctype': 'Foo', 'a': 1});
      expect(e.responseBodyRaw, contains('ValidationError'));
      expect(e.traceId, 'trace-417');
    }
  });

  test(
    '403 AuthException now carries the raw body (was previously dropped)',
    () async {
      final h = helperReturning(403);
      try {
        await h.put('/api/resource/Foo/x', body: {'doctype': 'Foo'});
        fail('expected throw');
      } on AuthException catch (e) {
        expect(e.statusCode, 403);
        expect(e.responseBodyRaw, contains('ValidationError'));
        expect(e.requestMethod, 'PUT');
        expect(e.traceId, isNull); // header absent → null, not an error
      }
    },
  );

  test('404 ApiException carries the raw body', () async {
    final h = helperReturning(404);
    try {
      await h.post('/api/resource/Foo', body: {'doctype': 'Foo'});
      fail('expected throw');
    } on ApiException catch (e) {
      expect(e.statusCode, 404);
      expect(e.responseBodyRaw, contains('ValidationError'));
    }
  });

  test(
    'a failed auth call carries a REDACTED requestBody, not the live '
    'password/otp/refresh_token — this field is stamped unconditionally '
    '(not gated by kDebugMode) and is surfaced by error_capture.dart, so an '
    'app that logs it on a failure must never see the real credential',
    () async {
      final h = helperReturning(401);
      try {
        await h.post(
          '/api/method/mobile_auth.verify_login_otp',
          body: {'tmp_id': 'tmp-abc123', 'otp': '123456'},
        );
        fail('expected throw');
      } on AuthException catch (e) {
        expect(e.requestBody, {'tmp_id': 'tmp-abc123', 'otp': '[REDACTED]'});
      }
    },
  );
}
