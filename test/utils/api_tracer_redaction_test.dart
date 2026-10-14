// Contract: the debug API tracer never writes a secret to the log.
//
// Security finding (14-Oct): ApiTracer printed raw request bodies (every
// non-GET) and raw response bodies (status >= 400), so the login call
// `mobile_auth.login` {username, password} put the password in logcat on
// debug builds.
//
// Redacted keys (case-insensitive, at any depth): password, pwd,
// new_password, old_password, access_token, refresh_token, api_secret,
// api_key, token, secret. Applies to request AND response bodies, whether
// they arrive as a Map/List, a JSON string, or a form-encoded string.
// Everything else stays visible so the tracer is still useful.
//
// Release mode (kDebugMode == false) is a compile-time constant and cannot
// be flipped inside `flutter test`; that contract is not covered here.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:frappe_mobile_sdk/src/utils/api_tracer.dart';

const _password = 'Pw-7f3e-SECRET-hunter2';
const _access = 'AT-9c1d-SECRET-access';
const _refresh = 'RT-44ab-SECRET-refresh';
const _apiKey = 'AK-0011-SECRET-key';
const _apiSecret = 'AS-2233-SECRET-apisecret';
const _token = 'TK-5566-SECRET-token';
const _secret = 'SC-7788-SECRET-secret';
const _pwd = 'PWD-99aa-SECRET-pwd';
const _newPw = 'NP-bbcc-SECRET-newpw';
const _oldPw = 'OP-ddee-SECRET-oldpw';

const _allSecrets = [
  _password,
  _access,
  _refresh,
  _apiKey,
  _apiSecret,
  _token,
  _secret,
  _pwd,
  _newPw,
  _oldPw,
];

void main() {
  late List<String> logged;
  late DebugPrintCallback original;

  setUp(() {
    logged = [];
    original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logged.add(message);
    };
  });

  tearDown(() {
    debugPrint = original;
  });

  String output() => logged.join('\n');

  void expectNoSecrets() {
    final out = output();
    for (final s in _allSecrets) {
      expect(out, isNot(contains(s)), reason: 'secret "$s" leaked:\n$out');
    }
  }

  test('sanity: tracer emits output in debug test runs', () {
    expect(kDebugMode, isTrue);
    ApiTracer.traceRequest(method: 'POST', url: 'http://x/a', body: {'a': 1});
    expect(output(), contains('[Frappe API] REQUEST POST http://x/a'));
  });

  group('request bodies', () {
    test('login_request_never_logs_password', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (req) async => http.Response(
            jsonEncode({'message': {'user': 'bob@x.org'}}),
            200,
          ),
        ),
      );

      await h.call(
        'mobile_auth.login',
        args: {'username': 'bob@x.org', 'password': _password},
      );

      final out = output();
      expect(out, contains('mobile_auth.login'));
      expect(out, isNot(contains(_password)));
    });

    test('login_request_keeps_non_secret_fields_visible', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (req) async => http.Response(jsonEncode({'message': {}}), 200),
        ),
      );

      await h.call(
        'mobile_auth.login',
        args: {'username': 'bob@x.org', 'password': _password},
      );

      final out = output();
      expect(out, contains('username'));
      expect(out, contains('bob@x.org'));
      expect(out, contains('password'), reason: 'key stays, value is masked');
    });

    test('map_body_redacts_every_secret_key_case_insensitively', () {
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/m',
        body: {
          'Password': _password,
          'pwd': _pwd,
          'NEW_PASSWORD': _newPw,
          'old_password': _oldPw,
          'Access_Token': _access,
          'refresh_token': _refresh,
          'api_secret': _apiSecret,
          'API_KEY': _apiKey,
          'token': _token,
          'Secret': _secret,
          'doctype': 'Member',
        },
      );

      expectNoSecrets();
      expect(output(), contains('Member'));
    });

    test('nested_map_and_list_secrets_are_redacted', () {
      ApiTracer.traceRequest(
        method: 'PUT',
        url: 'http://x/api/resource/User/bob',
        body: {
          'name': 'bob',
          'auth': {
            'creds': {'password': _password, 'note': 'keep-me-nested'},
            'tokens': [
              {'access_token': _access, 'kind': 'bearer-kind'},
              {'refresh_token': _refresh},
            ],
          },
        },
      );

      expectNoSecrets();
      final out = output();
      expect(out, contains('keep-me-nested'));
      expect(out, contains('bearer-kind'));
      expect(out, contains('bob'));
    });

    test('top_level_list_body_secrets_are_redacted', () {
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/bulk',
        body: [
          {'api_key': _apiKey, 'api_secret': _apiSecret, 'row': 'row-one'},
        ],
      );

      expectNoSecrets();
      expect(output(), contains('row-one'));
    });

    test('json_string_body_secrets_are_redacted', () {
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/m',
        body: jsonEncode({
          'usr': 'bob@x.org',
          'pwd': _pwd,
          'nested': {'secret': _secret},
        }),
      );

      expectNoSecrets();
      expect(output(), contains('bob@x.org'));
    });

    test('form_encoded_string_body_secrets_are_redacted', () {
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/login',
        body:
            'usr=bob%40x.org&pwd=$_pwd&Password=$_password&token=$_token&cmd=login',
      );

      expectNoSecrets();
      final out = output();
      expect(out, contains('usr='));
      expect(out, contains('cmd=login'));
    });

    test('long_body_secret_redacted_before_truncation', () {
      // A secret near the 500-char preview cut must not survive as a
      // partial value (e.g. JSON that fails to parse after truncation).
      final body = {
        'filler': 'f' * 470,
        'password': _password,
        'tail': 'tail-visible',
      };
      ApiTracer.traceRequest(method: 'POST', url: 'http://x/m', body: body);

      final out = output();
      // No 8+ char fragment of the password may appear.
      for (var i = 0; i + 8 <= _password.length; i++) {
        expect(out, isNot(contains(_password.substring(i, i + 8))),
            reason: 'password fragment leaked:\n$out');
      }
    });
  });

  group('url query strings', () {
    test('get_request_url_and_query_secrets_are_redacted', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (req) async => http.Response(jsonEncode({'message': 'ok'}), 200),
        ),
      );

      await h.get(
        '/api/method/m',
        queryParams: {
          'API_KEY': _apiKey,
          'token': _token,
          'doctype': 'Member',
        },
      );

      expectNoSecrets();
      final out = output();
      expect(out, contains('http://x/api/method/m'));
      expect(out, contains('doctype'));
      expect(out, contains('Member'));
    });

    test('post_request_url_query_secrets_are_redacted', () {
      ApiTracer.traceRequest(
        method: 'POST',
        url:
            'http://x/api/method/m?Access_Token=$_access&page=pg-visible&pwd=$_pwd',
        body: {'doctype': 'Member'},
      );

      expectNoSecrets();
      final out = output();
      expect(out, contains('http://x/api/method/m?'));
      expect(out, contains('page=pg-visible'));
    });

    test('response_url_query_secrets_are_redacted', () {
      ApiTracer.traceResponse(
        statusCode: 403,
        url: 'http://x/api/method/m?secret=$_secret&limit=lim-visible',
        body: 'forbidden',
      );

      expectNoSecrets();
      final out = output();
      expect(out, contains('http://x/api/method/m?'));
      expect(out, contains('limit=lim-visible'));
    });
  });

  group('response bodies', () {
    test('error_response_json_string_body_is_redacted', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (req) async => http.Response(
            jsonEncode({
              'exc_type': 'ValidationError',
              'message': 'bad request visible-msg',
              'echo': {
                'access_token': _access,
                'refresh_token': _refresh,
                'password': _password,
              },
            }),
            417,
          ),
        ),
      );

      await expectLater(
        h.post('/api/method/m', body: {'doctype': 'Member'}),
        throwsA(anything),
      );

      expectNoSecrets();
      final out = output();
      expect(out, contains('RESPONSE 417'));
      expect(out, contains('visible-msg'));
    });

    test('traceResponse_map_body_is_redacted', () {
      ApiTracer.traceResponse(
        statusCode: 500,
        url: 'http://x/m',
        body: {
          'message': 'server-said-this',
          'data': {'api_secret': _apiSecret, 'token': _token},
        },
      );

      expectNoSecrets();
      expect(output(), contains('server-said-this'));
    });

    test('traceResponse_form_encoded_body_is_redacted', () {
      ApiTracer.traceResponse(
        statusCode: 400,
        url: 'http://x/m',
        body: 'error=invalid_grant&refresh_token=$_refresh&state=st-visible',
      );

      expectNoSecrets();
      expect(output(), contains('st-visible'));
    });
  });

  group('wider key net', () {
    void expectAbsent(List<String> values) {
      final out = output();
      for (final v in values) {
        expect(out, isNot(contains(v)), reason: 'secret "$v" leaked:\n$out');
      }
    }

    test('session_and_oauth_keys_are_redacted', () {
      const vals = {
        'otp': 'OTP-1-SECRET',
        'tmp_id': 'TMP-2-SECRET',
        'sid': 'SID-3-SECRET',
        'csrf_token': 'CSRF-4-SECRET',
        'authorization': 'AUTHZ-5-SECRET',
        'cookie': 'COOKIE-6-SECRET',
        'client_secret': 'CS-7-SECRET',
        'code': 'CODE-8-SECRET',
        'code_verifier': 'CV-9-SECRET',
      };
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/m',
        body: {...vals, 'doctype': 'wider-visible'},
      );

      expectAbsent(vals.values.toList());
      expect(output(), contains('wider-visible'));
    });

    test('session_and_oauth_keys_are_redacted_in_error_response', () {
      ApiTracer.traceResponse(
        statusCode: 401,
        url: 'http://x/api/method/m',
        body: jsonEncode({
          'sid': 'SID-R-SECRET',
          'otp': 'OTP-R-SECRET',
          'message': 'resp-visible',
        }),
      );

      expectAbsent(['SID-R-SECRET', 'OTP-R-SECRET']);
      expect(output(), contains('resp-visible'));
    });

    test('key_match_ignores_case_underscore_and_hyphen', () {
      const vals = {
        'apiKey': 'CAMEL-AK-SECRET',
        'accessToken': 'CAMEL-AT-SECRET',
        'x-frappe-csrf-token': 'HDR-CSRF-SECRET',
        'Api-Secret': 'HYPH-AS-SECRET',
        'Refresh-Token': 'HYPH-RT-SECRET',
        'newPassword': 'CAMEL-NP-SECRET',
      };
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/m',
        body: {
          'nested': {...vals},
          'label': 'norm-visible',
        },
      );

      expectAbsent(vals.values.toList());
      expect(output(), contains('norm-visible'));
    });

    test('normalised_keys_are_redacted_in_url_query', () {
      ApiTracer.traceRequest(
        method: 'GET',
        url: 'http://x/api/method/m?apiKey=Q-AK-SECRET&Client-Secret=Q-CS-SECRET&page=q-visible',
      );

      expectAbsent(['Q-AK-SECRET', 'Q-CS-SECRET']);
      expect(output(), contains('page=q-visible'));
    });

    test('non_secret_lookalike_keys_stay_visible', () {
      // "Keep everything else": the wider net must not swallow ordinary
      // Swasti fields whose names merely contain a secret word.
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/m',
        body: {
          'pincode': '110001-pin',
          'country_code': 'IN-cc',
          'session_name': 'sess-visible',
        },
      );

      final out = output();
      expect(out, contains('110001-pin'));
      expect(out, contains('IN-cc'));
      expect(out, contains('sess-visible'));
    });
  });

  group('unparseable string bodies', () {
    test('colon_style_secret_is_not_logged_raw', () {
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/m',
        body: 'username: bob\npassword: hunter2-COLON-SECRET',
      );

      expect(output(), isNot(contains('hunter2-COLON-SECRET')));
    });

    test('truncated_json_secret_is_not_logged_raw', () {
      ApiTracer.traceRequest(
        method: 'POST',
        url: 'http://x/api/method/m',
        body: '{"usr":"bob","password":"TRUNC-PW-SECRET","access_token":"TRUNC-AT-SECRET"',
      );

      final out = output();
      expect(out, isNot(contains('TRUNC-PW-SECRET')));
      expect(out, isNot(contains('TRUNC-AT-SECRET')));
    });

    test('truncated_json_error_response_secret_is_not_logged_raw', () {
      ApiTracer.traceResponse(
        statusCode: 500,
        url: 'http://x/api/method/m',
        body: '<html>Traceback ... {"sid": "HTML-SID-SECRET", "Authorization": "Bearer HTML-BEARER-SECRET"',
      );

      final out = output();
      expect(out, isNot(contains('HTML-SID-SECRET')));
      expect(out, isNot(contains('HTML-BEARER-SECRET')));
    });
  });
}
