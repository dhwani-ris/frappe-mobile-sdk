// Fix A (T-A1..T-A4) — single-flight, non-destructive mobile-auth token refresh.
//
// Drives AuthService.forTesting + a counting MockClient + an in-memory
// AppDatabase (auth_tokens seeded via authTokenDao), plus a mock
// flutter_secure_storage channel so getBaseUrl() / the OAuth fallback don't hit
// a real platform plugin. The private single-flight refresh is exercised via
// the @visibleForTesting `debugTryRefreshMobileAuthToken()` seam.
//
// T-A1 concurrent 401s → EXACTLY ONE refresh HTTP call (single-flight); all
//   queued callers resolve true; token rotated; bearer == new token.
// T-A2 transient failure (503 / 2xx-without-access_token) → tokens SURVIVE,
//   session stays authenticated, restoreSession() still true, recovers next try
//   (no fall-through that wipes anything).
// T-A3 definitive rejection (401 / 417) → tokens WIPED, de-authenticated.
// T-A4 after a settled refresh, a later refresh starts a NEW single-flight
//   cycle (the in-flight future was cleared on completion).
import 'dart:async';
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

http.Response _json(Map body, int status) =>
    http.Response(jsonEncode(body), status);

void main() {
  const storageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late FrappeClient client;
  late AuthService authService;
  late int refreshPosts;
  late String? lastAuthHeader;
  late Future<http.Response> Function(http.Request req) refreshResponder;
  late Map<String, String> store;

  setUp(() async {
    // In-memory secure storage: baseUrl set, no OAuth tokens (so the OAuth
    // fallback cleanly returns false without a real plugin).
    store = <String, String>{'frappe_base_url': 'http://x'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async {
      final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
      switch (call.method) {
        case 'read':
          return store[args['key'] as String];
        case 'write':
          final v = args['value'] as String?;
          if (v == null) {
            store.remove(args['key'] as String);
          } else {
            store[args['key'] as String] = v;
          }
          return null;
        case 'delete':
          store.remove(args['key'] as String);
          return null;
        case 'deleteAll':
          store.clear();
          return null;
        case 'containsKey':
          return store.containsKey(args['key'] as String);
        case 'readAll':
          return Map<String, String>.from(store);
        default:
          return null;
      }
    });

    refreshPosts = 0;
    lastAuthHeader = null;
    refreshResponder = (req) async =>
        _json({'access_token': 'access-1', 'refresh_token': 'refresh-1'}, 200);

    final mock = MockClient((req) async {
      if (req.url.path.contains('mobile_auth.refresh_token')) {
        refreshPosts++;
        return refreshResponder(req);
      }
      lastAuthHeader = req.headers['Authorization'];
      return _json({'ok': 1}, 200);
    });

    db = await AppDatabase.inMemoryDatabase();
    await db.authTokenDao.insertToken(
      AuthTokenEntity(
        accessToken: 'access-0',
        refreshToken: 'refresh-0',
        user: 'alice@example.com',
        fullName: 'Alice',
        createdAt: 1,
      ),
    );
    client = FrappeClient('http://x', httpClient: mock);
    authService = AuthService.forTesting(client, database: db);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    await db.close();
  });

  test(
    'T-A1: concurrent refreshes trigger exactly ONE HTTP call; all callers succeed',
    () async {
      // Hold the refresh in-flight so all 5 callers genuinely queue on it.
      final gate = Completer<void>();
      refreshResponder = (req) async {
        await gate.future;
        return _json(
          {'access_token': 'access-1', 'refresh_token': 'refresh-1'},
          200,
        );
      };

      final futures = List.generate(
        5,
        (_) => authService.debugTryRefreshMobileAuthToken(),
      );
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      final results = await Future.wait(futures);

      expect(results, everyElement(isTrue));
      expect(
        refreshPosts,
        1,
        reason: 'single-flight: only the first caller hits the network',
      );

      final token = await db.authTokenDao.getCurrentToken();
      expect(token!.accessToken, 'access-1', reason: 'DB token rotated');
      expect(token.refreshToken, 'refresh-1');

      // Bearer now carries the new token (captured on a follow-up authed call).
      await client.rest.get('/api/method/ping');
      expect(lastAuthHeader, 'Bearer access-1');
    },
  );

  test(
    'T-A2: a transient refresh failure (503) keeps tokens + session and recovers',
    () async {
      expect(await authService.restoreSession(), isTrue);
      expect(authService.isAuthenticated, isTrue);

      refreshResponder =
          (req) async => _json({'exception': 'ServiceUnavailable'}, 503);
      final r = await authService.debugTryRefreshMobileAuthToken();
      expect(r, isFalse);

      final token = await db.authTokenDao.getCurrentToken();
      expect(token, isNotNull, reason: 'transient failure must NOT wipe tokens');
      expect(token!.accessToken, 'access-0', reason: 'token not rotated');
      expect(
        authService.isAuthenticated,
        isTrue,
        reason: 'session survives a transient refresh failure',
      );
      expect(
        await authService.restoreSession(),
        isTrue,
        reason: 'the stored session is still restorable',
      );

      // Server recovers → a follow-up refresh succeeds and rotates.
      refreshResponder = (req) async =>
          _json({'access_token': 'access-2', 'refresh_token': 'refresh-2'}, 200);
      expect(await authService.debugTryRefreshMobileAuthToken(), isTrue);
      expect((await db.authTokenDao.getCurrentToken())!.accessToken, 'access-2');
    },
  );

  test(
    'T-A2b: a 2xx refresh missing access_token keeps tokens (transient)',
    () async {
      await authService.restoreSession();
      refreshResponder = (req) async => _json({'refresh_token': 'r'}, 200);

      final r = await authService.debugTryRefreshMobileAuthToken();
      expect(r, isFalse);

      final token = await db.authTokenDao.getCurrentToken();
      expect(token, isNotNull);
      expect(token!.accessToken, 'access-0');
      expect(authService.isAuthenticated, isTrue);
    },
  );

  test(
    'T-A3: a definitive rejection (401) wipes tokens and de-authenticates',
    () async {
      expect(await authService.restoreSession(), isTrue);
      expect(authService.isAuthenticated, isTrue);

      refreshResponder =
          (req) async => _json({'exception': 'Unauthenticated'}, 401);
      final r = await authService.debugTryRefreshMobileAuthToken();
      expect(r, isFalse);

      expect(
        await db.authTokenDao.getCurrentToken(),
        isNull,
        reason: 'a dead refresh token is wiped by design',
      );
      expect(authService.isAuthenticated, isFalse);
    },
  );

  test('T-A3b: a 417 validation rejection is also definitive (wipes)', () async {
    await authService.restoreSession();
    refreshResponder = (req) async =>
        _json({'exception': 'Validation', 'message': 'bad grant'}, 417);

    final r = await authService.debugTryRefreshMobileAuthToken();
    expect(r, isFalse);
    expect(await db.authTokenDao.getCurrentToken(), isNull);
    expect(authService.isAuthenticated, isFalse);
  });

  test(
    'T-A4: after a completed refresh, a later refresh starts a NEW cycle',
    () async {
      refreshResponder = (req) async =>
          _json({'access_token': 'access-1', 'refresh_token': 'refresh-1'}, 200);
      expect(await authService.debugTryRefreshMobileAuthToken(), isTrue);
      expect(refreshPosts, 1);
      expect((await db.authTokenDao.getCurrentToken())!.accessToken, 'access-1');

      // The in-flight future was cleared on completion → a fresh HTTP call.
      refreshResponder = (req) async =>
          _json({'access_token': 'access-9', 'refresh_token': 'refresh-9'}, 200);
      expect(await authService.debugTryRefreshMobileAuthToken(), isTrue);
      expect(
        refreshPosts,
        2,
        reason: 'whenComplete cleared _refreshInFlight; new refresh hit network',
      );
      expect((await db.authTokenDao.getCurrentToken())!.accessToken, 'access-9');
    },
  );
}
