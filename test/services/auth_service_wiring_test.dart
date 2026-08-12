// Exercises the REAL AuthService methods end-to-end (login/persist, the
// aged-token refresh path inside restoreSession, and single-flight), rather
// than just the debug seams covered in auth_service_cooldown_test.dart.
//
// `restoreSession` is the only PUBLIC entry point that reaches the private
// `_tryRefreshMobileAuthToken` / `_doRefreshMobileAuthToken` chain without an
// `onTokenExpired` 401 round trip: when the stored token is older than the
// mirrored 24h TTL (minus a 5-minute skew), `restoreSession(isOnline: true)`
// calls the same refresh path a real 401 would. Tests below age the token to
// land on that path deliberately.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';
import 'package:frappe_mobile_sdk/src/services/session_health.dart';

/// `AuthService.getBaseUrl`/`restoreSession` read `FlutterSecureStorage`,
/// which has no platform implementation under `flutter test`. Stubbing its
/// method channel directly is the only way to reach those code paths from a
/// unit test without a real device.
const _secureStorageChannel = MethodChannel(
  'plugins.it_nomads.com/flutter_secure_storage',
);

void _mockSecureStorage({
  String? baseUrl,
  String? oauthRefreshToken,
  String? oauthClientId,
  String? oauthClientSecret,
}) {
  final values = <String, String?>{
    'frappe_base_url': baseUrl,
    'frappe_oauth_refresh_token': oauthRefreshToken,
    'frappe_oauth_client_id': oauthClientId,
    'frappe_oauth_client_secret': oauthClientSecret,
  };
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, (call) async {
        switch (call.method) {
          case 'read':
            final key = (call.arguments as Map)['key'] as String;
            return values[key];
          case 'readAll':
            return <String, String>{};
          case 'containsKey':
            return false;
          default:
            return null;
        }
      });
}

/// A token old enough to cross the mirrored 24h-minus-5m-skew threshold in
/// `restoreSession`, so it takes the refresh branch instead of the cached-
/// bearer fast path.
int _agedCreatedAt() =>
    DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
  });
  tearDown(() async => db.close());

  group('(a) fresh credential clears the dead-session latch', () {
    test('persistExternalLoginResponse after debugMarkExpired leaves refresh '
        're-armed and session healthy', () async {
      final auth = AuthService.forTesting(
        FrappeClient('http://x'),
        database: db,
      );

      auth.debugMarkExpired('dead@example.com');
      expect(auth.debugRefreshAllowed(), isFalse);
      expect(auth.sessionHealth.value, SessionHealth.expired);

      await auth.persistExternalLoginResponse({
        'access_token': 'AT-fresh',
        'refresh_token': 'RT-fresh',
        'user': 'alive@example.com',
      });

      expect(
        auth.debugRefreshAllowed(),
        isTrue,
        reason:
            'a fresh login must retire the latch, or the refresh path '
            'stays permanently gated post re-login',
      );
      expect(auth.sessionHealth.value, SessionHealth.healthy);
      expect(auth.expiredSessionEmail, isNull);
    });
  });

  group('(b) successful refresh recovers session health', () {
    test('restoreSession refresh success calls markSessionRecovered', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/method/mobile_auth.refresh_token');
          return http.Response(
            jsonEncode({'access_token': 'AT-new', 'refresh_token': 'RT-new'}),
            200,
          );
        }),
      );
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'AT-old',
          refreshToken: 'RT-old',
          user: 'user@example.com',
          createdAt: _agedCreatedAt(),
        ),
      );
      _mockSecureStorage(baseUrl: 'http://x');
      final auth = AuthService.forTesting(client, database: db);

      // Start from a real degraded state (not the trivial default-healthy
      // case) so a pass here proves markSessionRecovered ran.
      var now = DateTime(2026, 8, 7, 12, 0, 0);
      auth.clock = () => now;
      auth.debugRecordTransientFailure(rateLimited: false);
      expect(auth.sessionHealth.value, SessionHealth.degraded);
      now = now.add(const Duration(seconds: 31)); // past the 30s cooldown

      final restored = await auth.restoreSession(isOnline: true);

      expect(restored, isTrue);
      expect(auth.sessionHealth.value, SessionHealth.healthy);
      expect(auth.debugRefreshAllowed(), isTrue);
    });
  });

  group(
    '(c) definitive rejection (417) captures email before deleting the token',
    () {
      test(
        'expiredSessionEmail is populated and the token row is gone',
        () async {
          final client = FrappeClient(
            'http://x',
            httpClient: MockClient((req) async {
              return http.Response(
                jsonEncode({'message': 'Invalid or expired refresh token'}),
                417,
              );
            }),
          );
          await db.authTokenDao.insertToken(
            AuthTokenEntity(
              accessToken: 'AT-old',
              refreshToken: 'RT-dead',
              user: 'dead@example.com',
              createdAt: _agedCreatedAt(),
            ),
          );
          _mockSecureStorage(baseUrl: 'http://x');
          final auth = AuthService.forTesting(client, database: db);

          await auth.restoreSession(isOnline: true);

          expect(auth.expiredSessionEmail, 'dead@example.com');
          expect(auth.sessionHealth.value, SessionHealth.expired);
          expect(auth.debugRefreshAllowed(), isFalse);
          expect(await db.authTokenDao.getCurrentToken(), isNull);
        },
      );
    },
  );

  group('(d) non-definitive failure (429) keeps the token row', () {
    test('token survives a rate-limit lockout', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(jsonEncode({'message': 'slow down'}), 429);
        }),
      );
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'AT-old',
          refreshToken: 'RT-old',
          user: 'user@example.com',
          createdAt: _agedCreatedAt(),
        ),
      );
      _mockSecureStorage(baseUrl: 'http://x');
      final auth = AuthService.forTesting(client, database: db);

      final restored = await auth.restoreSession(isOnline: true);

      // The row survives, so restoreSession installs it as the best
      // available credential rather than forcing a re-login.
      expect(restored, isTrue);
      expect(auth.expiredSessionEmail, isNull);
      expect(auth.sessionHealth.value, SessionHealth.degraded);
      expect(auth.debugRefreshAllowed(), isFalse);
      final surviving = await db.authTokenDao.getCurrentToken();
      expect(surviving, isNotNull);
      expect(surviving!.refreshToken, 'RT-old');
    });
  });

  group('(e) single-flight refresh', () {
    test(
      'concurrent restoreSession calls share ONE in-flight refresh',
      () async {
        var refreshCalls = 0;
        final client = FrappeClient(
          'http://x',
          httpClient: MockClient((req) async {
            if (req.url.path == '/api/method/mobile_auth.refresh_token') {
              refreshCalls++;
              // Hold the response open long enough that both callers are
              // provably overlapping when the second one arrives.
              await Future.delayed(const Duration(milliseconds: 50));
              return http.Response(
                jsonEncode({
                  'access_token': 'AT-new',
                  'refresh_token': 'RT-new',
                }),
                200,
              );
            }
            return http.Response('{}', 200);
          }),
        );
        await db.authTokenDao.insertToken(
          AuthTokenEntity(
            accessToken: 'AT-old',
            refreshToken: 'RT-old',
            user: 'user@example.com',
            createdAt: _agedCreatedAt(),
          ),
        );
        _mockSecureStorage(baseUrl: 'http://x');
        final auth = AuthService.forTesting(client, database: db);

        final results = await Future.wait([
          auth.restoreSession(isOnline: true),
          auth.restoreSession(isOnline: true),
        ]);

        expect(
          refreshCalls,
          1,
          reason:
              'two overlapping callers must share one refresh, or each '
              '401 wave fires a competing refresh against the backend',
        );
        expect(results, everyElement(isTrue));
      },
    );
  });

  group(
    '(f) a successful OAuth fallback clears a stale mobile-refresh latch',
    () {
      test(
        'degraded status + cooldown armed by the mobile dead-end are cleared '
        'once the OAuth fallback lands a live credential',
        () async {
          // Empty refresh_token on the stored mobile token trips the (a)
          // dead-end in _doRefreshMobileAuthToken, which arms degraded +
          // cooldown before falling through to the OAuth fallback below.
          await db.authTokenDao.insertToken(
            AuthTokenEntity(
              accessToken: 'AT-old',
              refreshToken: '',
              user: 'user@example.com',
              createdAt: _agedCreatedAt(),
            ),
          );
          _mockSecureStorage(
            baseUrl: 'http://x',
            oauthRefreshToken: 'OAUTH-RT-old',
            oauthClientId: 'client-1',
          );
          final auth = AuthService.forTesting(
            FrappeClient('http://x'),
            database: db,
          );

          // OAuth2Helper calls the top-level http.post directly (no injectable
          // client), so the fallback's network call is intercepted via
          // package:http's zoned Client() override instead of FrappeClient's
          // httpClient.
          final restored = await http.runWithClient(
            () => auth.restoreSession(isOnline: true),
            () => MockClient((req) async {
              return http.Response(
                jsonEncode({
                  'access_token': 'OAUTH-AT-new',
                  'refresh_token': 'OAUTH-RT-new',
                  'expires_in': 3600,
                }),
                200,
              );
            }),
          );

          expect(restored, isTrue);
          expect(
            auth.sessionHealth.value,
            SessionHealth.healthy,
            reason:
                'a live credential from the OAuth fallback makes the '
                'mobile-refresh dead-end degraded status stale',
          );
          expect(
            auth.debugRefreshAllowed(),
            isTrue,
            reason:
                'the cooldown armed by the mobile dead-end must not '
                'outlive a fallback that already produced a working session',
          );
        },
      );
    },
  );

  group('(g) loginWithApiKey clears the dead-session latch', () {
    test(
      'a successful API-key login re-arms refresh after a dead session',
      () async {
        _mockSecureStorage();
        final auth = AuthService.forTesting(
          FrappeClient('http://x'),
          database: db,
        );

        auth.debugMarkExpired('dead@example.com');
        expect(auth.debugRefreshAllowed(), isFalse);

        final ok = await auth.loginWithApiKey('KEY-1', 'SECRET-1');

        expect(ok, isTrue);
        expect(
          auth.debugRefreshAllowed(),
          isTrue,
          reason:
              'loginWithApiKey does not route through '
              '_processLoginResponse, so it needs its own latch clear — '
              'otherwise a mobile-login -> dead-refresh -> API-key-re-login '
              'sequence leaves the refresh path permanently gated',
        );
        expect(auth.sessionHealth.value, SessionHealth.healthy);
        expect(auth.expiredSessionEmail, isNull);
      },
    );
  });

  group('(h) the OAuth leg classifies failures like the mobile leg', () {
    /// Same as [_mockSecureStorage] but records every deleted key, so a test
    /// can assert whether the OAuth grant was wiped.
    List<String> mockStorageRecordingDeletes() {
      final deleted = <String>[];
      final values = <String, String?>{
        'frappe_base_url': 'http://x',
        'frappe_oauth_refresh_token': 'OAUTH-RT-old',
        'frappe_oauth_client_id': 'client-1',
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_secureStorageChannel, (call) async {
            switch (call.method) {
              case 'read':
                return values[(call.arguments as Map)['key'] as String];
              case 'delete':
                deleted.add((call.arguments as Map)['key'] as String);
                return null;
              case 'readAll':
                return <String, String>{};
              case 'containsKey':
                return false;
              default:
                return null;
            }
          });
      return deleted;
    }

    /// Drives `restoreSession` down to the OAuth fallback (the stored mobile
    /// token carries an empty refresh token, which dead-ends the mobile leg),
    /// with the OAuth call answered by [oauthResponder].
    Future<({AuthService auth, List<String> deleted})> runOAuth(
      Future<http.Response> Function(http.Request) oauthResponder,
    ) async {
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'AT-old',
          refreshToken: '',
          user: 'user@example.com',
          createdAt: _agedCreatedAt(),
        ),
      );
      final deleted = mockStorageRecordingDeletes();
      final auth = AuthService.forTesting(
        FrappeClient('http://x'),
        database: db,
      );
      await http.runWithClient(
        () => auth.restoreSession(isOnline: true),
        () => MockClient(oauthResponder),
      );
      return (auth: auth, deleted: deleted);
    }

    test('a 400 from the OAuth grant reports the session as EXPIRED', () async {
      // 400 is the status that MATTERS on this leg, and the earlier version of
      // this test asserted a pairing the server cannot emit: `invalid_grant`
      // with a 401. `get_token` puts the oauthlib error object in the body and
      // forces `http_status_code = 400` on it, so a dead grant is a 400 — which
      // the shared `{401, 403, 417}` predicate read as transient. The suite was
      // green with the bug intact because of that fabricated pairing.
      final r = await runOAuth(
        (_) async => http.Response(jsonEncode({'error': 'invalid_grant'}), 400),
      );
      expect(r.auth.sessionHealth.value, SessionHealth.expired);
      expect(
        r.deleted,
        contains('frappe_oauth_refresh_token'),
        reason: 'a definitively rejected grant SHOULD still be cleared',
      );
    });

    test('a 401 from the OAuth grant still reports EXPIRED', () async {
      // Kept as defence in depth: a proxy or a differently-configured
      // deployment answering 401 must classify the same way.
      final r = await runOAuth((_) async => http.Response('unauthorized', 401));
      expect(r.auth.sessionHealth.value, SessionHealth.expired);
      expect(r.deleted, contains('frappe_oauth_refresh_token'));
    });

    test(
      'a 200 carrying an RFC 6749 error is EXPIRED, not a recovery',
      () async {
        // `get_token` is reached through Frappe's `/api/method` wrapper, so a
        // deployment that does not force the 400 hands back the error object on
        // a 200. `OAuth2TokenResponse.fromJson` defaulted `access_token` to '',
        // so this path used to store an empty Bearer and return SUCCESS.
        final r = await runOAuth(
          (_) async =>
              http.Response(jsonEncode({'error': 'invalid_grant'}), 200),
        );
        expect(r.auth.sessionHealth.value, SessionHealth.expired);
        expect(r.deleted, contains('frappe_oauth_refresh_token'));
      },
    );

    test(
      'a 200 with no access_token KEEPS the grant and does NOT recover',
      () async {
        // The M1 hole: an empty `access_token` was stored, `setBearerToken('')`
        // was called, and the refresh reported success — after which
        // `markSessionRecovered()` published `healthy` for a session that 401s on
        // every request. A 200 that is not a token response says nothing about
        // the grant, so the grant is kept and the failure is transient.
        final r = await runOAuth(
          (_) async => http.Response(jsonEncode({'token_type': 'Bearer'}), 200),
        );
        expect(
          r.deleted,
          isNot(contains('frappe_oauth_refresh_token')),
          reason: 'a malformed 200 is not a statement about the credential',
        );
        expect(
          r.auth.sessionHealth.value,
          isNot(SessionHealth.healthy),
          reason: 'reporting healthy here is the bug — nothing was recovered',
        );
        expect(r.auth.sessionHealth.value, isNot(SessionHealth.expired));
      },
    );

    test('a transport failure KEEPS the OAuth grant', () async {
      // Before: any error cleared the tokens, so opening the app offline
      // destroyed a perfectly good grant and stranded the user behind a login
      // screen they could not reach.
      final r = await runOAuth((_) async => throw const _TransportFailure());
      expect(
        r.deleted,
        isNot(contains('frappe_oauth_refresh_token')),
        reason: 'an offline user must not lose their OAuth grant',
      );
      expect(
        r.auth.sessionHealth.value,
        isNot(SessionHealth.expired),
        reason: 'the session is not expired — the network is unavailable',
      );
    });

    test('a 5xx from the OAuth grant KEEPS it', () async {
      final r = await runOAuth(
        (_) async => http.Response('upstream exploded', 502),
      );
      expect(r.deleted, isNot(contains('frappe_oauth_refresh_token')));
      expect(r.auth.sessionHealth.value, isNot(SessionHealth.expired));
    });
  });
}

/// Stands in for a dropped socket on the OAuth call.
class _TransportFailure implements Exception {
  const _TransportFailure();
  @override
  String toString() => 'SocketException: Network is unreachable';
}
