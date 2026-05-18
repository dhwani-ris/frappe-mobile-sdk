import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/auth.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

class _SpyStorage implements SessionStorage {
  String? _current;
  bool cleared = false;

  set returnOnGet(String? v) => _current = v;
  String? get saved => _current;

  @override
  Future<void> clearSession() async {
    cleared = true;
    _current = null;
  }

  @override
  Future<String?> getSession() async => _current;

  @override
  Future<void> saveSession(String sid) async => _current = sid;
}

void main() {
  group('InMemorySessionStorage', () {
    test('round-trips sid; clearSession resets', () async {
      final s = InMemorySessionStorage();
      expect(await s.getSession(), isNull);
      await s.saveSession('SID-1');
      expect(await s.getSession(), 'SID-1');
      await s.clearSession();
      expect(await s.getSession(), isNull);
    });
  });

  group('AuthService.initialize', () {
    test('restores sid cookie from storage onto RestHelper', () async {
      Map<String, String>? sentHeaders;
      final rest = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sentHeaders = req.headers;
          return http.Response(jsonEncode({'ok': 1}), 200);
        }),
      );
      final auth = AuthService(
        rest,
        sessionStorage: _SpyStorage()..returnOnGet = 'STORED-SID',
      );
      await auth.initialize();

      // Trigger any request; the sid should be on the Cookie header.
      await rest.get('/api/method/x');
      expect(sentHeaders!['Cookie'], contains('sid=STORED-SID'));
    });

    test('no-op when storage returns null', () async {
      Map<String, String>? sentHeaders;
      final rest = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sentHeaders = req.headers;
          return http.Response(jsonEncode({'ok': 1}), 200);
        }),
      );
      final auth = AuthService(rest, sessionStorage: _SpyStorage());
      await auth.initialize();
      await rest.get('/api/method/x');
      expect(sentHeaders!.containsKey('Cookie'), isFalse);
    });
  });

  group('setApiKey', () {
    test('forwards to RestHelper (Authorization: token K:S)', () async {
      Map<String, String>? sentHeaders;
      final rest = RestHelper(
        'http://x',
        client: MockClient((req) async {
          sentHeaders = req.headers;
          return http.Response(jsonEncode({'ok': 1}), 200);
        }),
      );
      final auth = AuthService(rest);
      auth.setApiKey('K', 'S');
      await rest.get('/api/method/x');
      expect(sentHeaders!['Authorization'], 'token K:S');
    });
  });

  group('logout', () {
    test(
      'POSTs /api/method/mobile_auth.logout and clears local state',
      () async {
        final spy = _SpyStorage()..returnOnGet = 'SID-X';
        String? hitPath;
        final rest = RestHelper(
          'http://x',
          client: MockClient((req) async {
            hitPath = req.url.path;
            return http.Response(jsonEncode({'ok': 1}), 200);
          }),
        );
        final auth = AuthService(rest, sessionStorage: spy);
        await auth.initialize();

        await auth.logout();

        expect(hitPath, '/api/method/mobile_auth.logout');
        expect(spy.cleared, isTrue);

        // After logout, the next request must not carry the sid cookie —
        // RestHelper.clearSession was called.
        Map<String, String>? followupHeaders;
        final restAfter = RestHelper(
          'http://x',
          client: MockClient((req) async {
            followupHeaders = req.headers;
            return http.Response(jsonEncode({'ok': 1}), 200);
          }),
        );
        // Carry the same SID into the new RestHelper would happen via
        // initialize(), which now reads from cleared storage → no cookie.
        final authAfter = AuthService(restAfter, sessionStorage: spy);
        await authAfter.initialize();
        await restAfter.get('/api/method/x');
        expect(followupHeaders!.containsKey('Cookie'), isFalse);
      },
    );

    test('local cleanup runs even if server logout fails (5xx)', () async {
      final spy = _SpyStorage()..returnOnGet = 'SID-X';
      final rest = RestHelper(
        'http://x',
        client: MockClient(
          (_) async => http.Response(jsonEncode({'err': 'boom'}), 500),
        ),
      );
      final auth = AuthService(rest, sessionStorage: spy);
      await auth.initialize();

      // Must NOT throw — finally block runs cleanup.
      await auth.logout();
      expect(spy.cleared, isTrue);
    });
  });
}
