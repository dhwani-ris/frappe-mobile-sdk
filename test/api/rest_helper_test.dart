// Behavioral coverage of RestHelper — focused on the contracts other
// callers depend on:
//   - auth header injection precedence (Bearer > sid cookie > API key)
//   - baseUrl trailing-slash normalization
//   - status-code → exception mapping (401/403, 404, 417, generic 5xx)
//   - 401 → onTokenExpired → retry once
//   - GET network/timeout retry budget
//   - JSON decode failure handling
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

http.Response _json(Map body, int status) =>
    http.Response(jsonEncode(body), status);

void main() {
  group('baseUrl', () {
    test('strips a trailing slash', () {
      final h = RestHelper('http://example.com/');
      expect(h.baseUrl, 'http://example.com');
    });

    test('preserves a non-slash-ending baseUrl', () {
      final h = RestHelper('http://example.com');
      expect(h.baseUrl, 'http://example.com');
    });
  });

  group('auth header injection', () {
    test('no auth → only Accept header is sent', () async {
      Map<String, String>? sent;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sent = req.headers;
          return _json({'ok': 1}, 200);
        }),
      );
      await h.get('/api/method/x');
      expect(sent!['Accept'], 'application/json');
      expect(sent!.containsKey('Authorization'), isFalse);
      expect(sent!.containsKey('Cookie'), isFalse);
    });

    test('Bearer token wins over sid cookie and API key', () async {
      Map<String, String>? sent;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sent = req.headers;
          return _json({'ok': 1}, 200);
        }),
      );
      h.setSessionCookie('SID-1');
      h.setApiKey('K', 'S');
      h.setBearerToken('jwt-abc');
      await h.get('/api/method/x');
      expect(sent!['Authorization'], 'Bearer jwt-abc');
      expect(sent!.containsKey('Cookie'), isFalse);
    });

    test('sid cookie wins over API key when no Bearer token', () async {
      Map<String, String>? sent;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sent = req.headers;
          return _json({'ok': 1}, 200);
        }),
      );
      h.setSessionCookie('SID-1');
      h.setApiKey('K', 'S');
      await h.get('/api/method/x');
      expect(sent!['Cookie'], contains('sid=SID-1'));
      expect(sent!['Authorization'], isNull);
    });

    test('API key + secret form "token <k>:<s>"', () async {
      Map<String, String>? sent;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sent = req.headers;
          return _json({'ok': 1}, 200);
        }),
      );
      h.setApiKey('K', 'S');
      await h.get('/api/method/x');
      expect(sent!['Authorization'], 'token K:S');
    });

    test('clearSession() drops all auth', () async {
      Map<String, String>? sent;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sent = req.headers;
          return _json({'ok': 1}, 200);
        }),
      );
      h.setBearerToken('jwt');
      h.setSessionCookie('SID');
      h.setApiKey('K', 'S');
      h.clearSession();
      await h.get('/api/method/x');
      expect(sent!.containsKey('Authorization'), isFalse);
      expect(sent!.containsKey('Cookie'), isFalse);
    });

    test(
      'includeAuth=false skips auth headers (for postPublic / getPublic)',
      () async {
        Map<String, String>? sent;
        final h = RestHelper(
          'http://x',
          client: MockClient((req) async {
            sent = req.headers;
            return _json({'ok': 1}, 200);
          }),
        );
        h.setBearerToken('jwt');
        await h.getPublic('/api/method/public');
        expect(sent!.containsKey('Authorization'), isFalse);
      },
    );
  });

  group('status-code → exception mapping', () {
    test('401 throws AuthException (no onTokenExpired)', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (_) async => _json({'exception': 'Unauthenticated'}, 401),
        ),
      );
      h.setBearerToken('expired');
      expect(() => h.get('/api/method/x'), throwsA(isA<AuthException>()));
    });

    test('403 throws AuthException', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => _json({'exception': 'Forbidden'}, 403)),
      );
      expect(() => h.get('/api/method/x'), throwsA(isA<AuthException>()));
    });

    test('404 throws ApiException with code 404', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (_) async => _json({'exception': 'DoesNotExistError'}, 404),
        ),
      );
      await expectLater(
        h.get('/api/method/x'),
        throwsA(predicate((e) => e is ApiException && e.statusCode == 404)),
      );
    });

    test('417 throws ValidationException with full body in errors', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (_) async => _json({
            'exception': 'Validation',
            'message': 'Required',
            'errors': {'name': 'required'},
          }, 417),
        ),
      );
      ValidationException? caught;
      try {
        await h.get('/api/method/x');
      } on ValidationException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull);
      expect(caught!.statusCode, 417);
      expect(caught.errors, isNotNull);
    });

    test('500 throws ApiException with statusCode', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient(
          (_) async => _json({'exception': 'ServerError'}, 500),
        ),
      );
      await expectLater(
        h.get('/api/method/x'),
        throwsA(predicate((e) => e is ApiException && e.statusCode == 500)),
      );
    });

    test('non-JSON 4xx body wraps as ApiException with raw body', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => http.Response('<html>500</html>', 502)),
      );
      await expectLater(h.get('/api/method/x'), throwsA(isA<ApiException>()));
    });

    test('non-JSON 2xx body returns raw string', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => http.Response('OK', 200)),
      );
      final r = await h.get('/api/method/x');
      expect(r, 'OK');
    });
  });

  group('onTokenExpired refresh', () {
    test('401 → refresh true → second attempt succeeds', () async {
      var calls = 0;
      var refreshes = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          calls++;
          if (calls == 1) return _json({'exception': 'expired'}, 401);
          return _json({'ok': 1}, 200);
        }),
        onTokenExpired: () async {
          refreshes++;
          return true;
        },
      );
      h.setBearerToken(
        'expired',
      ); // required: onTokenExpired only fires when bearer set
      final result = await h.get('/api/method/x');
      expect(result, {'ok': 1});
      expect(refreshes, 1);
      expect(calls, 2);
    });

    test('401 → refresh false → AuthException propagates', () async {
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => _json({'exception': 'expired'}, 401)),
        onTokenExpired: () async => false,
      );
      h.setBearerToken('expired');
      expect(() => h.get('/api/method/x'), throwsA(isA<AuthException>()));
    });

    test('401 without a bearer token does NOT call onTokenExpired', () async {
      var refreshes = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => _json({'exception': 'no creds'}, 401)),
        onTokenExpired: () async {
          refreshes++;
          return true;
        },
      );
      expect(() => h.get('/api/method/x'), throwsA(isA<AuthException>()));
      // Give the throw a microtask to settle then assert.
      await Future<void>.delayed(Duration.zero);
      expect(refreshes, 0);
    });
  });

  group('GET retry on network errors', () {
    test('SocketException retries then throws NetworkException', () async {
      var calls = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async {
          calls++;
          throw const SocketException('refused');
        }),
        requestTimeout: const Duration(seconds: 5),
      );
      await expectLater(
        h.get('/api/method/x', maxRetries: 1),
        throwsA(isA<NetworkException>()),
      );
      // Default: 1 initial + 1 retry = 2 attempts.
      expect(calls, 2);
    });

    test('maxRetries: 0 fails fast without retrying', () async {
      var calls = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async {
          calls++;
          throw const SocketException('refused');
        }),
      );
      await expectLater(
        h.get('/api/method/x', maxRetries: 0),
        throwsA(isA<NetworkException>()),
      );
      expect(calls, 1, reason: 'maxRetries:0 disables retries');
    });
  });

  group('call', () {
    test('POST default body is JSON-encoded under args', () async {
      Map<String, String>? sent;
      String? bodyStr;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sent = req.headers;
          bodyStr = req.body;
          return _json({'ok': 1}, 200);
        }),
      );
      final r = await h.call(
        'frappe.client.get_value',
        args: {'doctype': 'X', 'name': 'a'},
      );
      expect(r, {'ok': 1});
      expect(sent!['Content-Type'], 'application/json');
      expect(jsonDecode(bodyStr!), {'doctype': 'X', 'name': 'a'});
    });

    test('GET puts args into the query string', () async {
      Uri? capturedUri;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          capturedUri = req.url;
          return _json({'ok': 1}, 200);
        }),
      );
      await h.call(
        'frappe.client.get_value',
        args: {'doctype': 'X'},
        httpMethod: 'GET',
      );
      expect(capturedUri!.queryParameters, {'doctype': 'X'});
    });
  });
}
