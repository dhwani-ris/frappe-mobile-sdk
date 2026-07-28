// Fix A (T-A5, T-A6) — RestHelper's 401-refresh hook.
//
// T-A5 (deadlock/recursion guard): a PUBLIC request (includeAuth:false —
//   postPublic/getPublic, which the mobile-auth refresh call itself uses) must
//   NEVER re-enter `onTokenExpired` on a 401, even with a bearer set. Otherwise
//   a 401 on the refresh call would recurse into another refresh → deadlock.
// T-A6: two concurrent authed requests that each 401-then-200 both retry and
//   succeed — the per-request retry loop is intact under concurrency.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

http.Response _json(Map body, int status) =>
    http.Response(jsonEncode(body), status);

void main() {
  group('T-A5: public requests never trigger the 401 refresh hook', () {
    test('getPublic on 401 does NOT invoke onTokenExpired', () async {
      var refreshes = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => _json({'exception': 'expired'}, 401)),
        onTokenExpired: () async {
          refreshes++;
          return true;
        },
      );
      // Bearer present — the only refresh precondition besides includeAuth.
      h.setBearerToken('jwt');

      await expectLater(
        h.getPublic('/api/method/mobile_auth.refresh_token'),
        throwsA(isA<AuthException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        refreshes,
        0,
        reason: 'includeAuth:false must not re-enter refresh (deadlock guard)',
      );
    });

    test('postPublic on 401 does NOT invoke onTokenExpired', () async {
      var refreshes = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((_) async => _json({'exception': 'expired'}, 401)),
        onTokenExpired: () async {
          refreshes++;
          return true;
        },
      );
      h.setBearerToken('jwt');

      await expectLater(
        h.postPublic('/api/method/mobile_auth.refresh_token'),
        throwsA(isA<AuthException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(refreshes, 0);
    });
  });

  group('T-A6: concurrent 401s each retry after refresh', () {
    test('two parallel authed GETs (each 401→200) both succeed', () async {
      final attemptsByPath = <String, int>{};
      var refreshes = 0;
      final h = RestHelper(
        'http://x',
        client: MockClient((req) async {
          final path = req.url.path;
          final n = (attemptsByPath[path] ?? 0) + 1;
          attemptsByPath[path] = n;
          // First hit per path 401s; the post-refresh retry succeeds.
          if (n == 1) return _json({'exception': 'expired'}, 401);
          return _json({'ok': path}, 200);
        }),
        onTokenExpired: () async {
          refreshes++;
          return true;
        },
      );
      h.setBearerToken('jwt');

      final results = await Future.wait([
        h.get('/api/method/a'),
        h.get('/api/method/b'),
      ]);

      expect((results[0] as Map)['ok'], '/api/method/a');
      expect((results[1] as Map)['ok'], '/api/method/b');
      expect(refreshes, greaterThanOrEqualTo(1));
      // Per path: 1 (401) + 1 (200 retry) = 2 attempts.
      expect(attemptsByPath['/api/method/a'], 2);
      expect(attemptsByPath['/api/method/b'], 2);
    });
  });
}
