// SPEC-0016 Part A — no stale credential on the sign-in request.
//
// Cause (SPEC-0016 §3.1): Android auto-backup restores the SDK's auth-token
// row; restoreSession() loads it into the REST bearer; the server rejects it;
// the refresh is definitively rejected and the row is deleted, but the bearer
// stays in RestHelper. login() then posts mobile_auth.login through the
// AUTHENTICATED rest.call, so the dead bearer rides along, Frappe answers 401
// and the user sees "Incorrect username or password."
//
// The fake server below behaves like Frappe in that respect: any request that
// carries an Authorization header whose bearer it did not issue gets a 401,
// even on a guest-allowed method.
//
// Contracts covered (SPEC-0016 §3.3):
//   SDK_LOGIN_SENDS_NO_STORED_CREDENTIAL
//   SDK_OTP_LOGIN_SENDS_NO_STORED_CREDENTIAL
//   SDK_REJECTED_REFRESH_CLEARS_BEARER
//   SDK_TRANSIENT_REFRESH_KEEPS_BEARER (pin)
//   SDK_SIGN_IN_AFTER_DEAD_RESTORED_TOKEN_SUCCEEDS (the unit-level repro)
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

const _deadAccess = 'dead-access-from-backup';
const _deadRefresh = 'dead-refresh-from-backup';
const _freshAccess = 'fresh-access-1';
const _freshRefresh = 'fresh-refresh-1';

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
  late AuthService auth;
  late Map<String, String> store;

  /// Every request the fake server received, in order.
  late List<http.Request> requests;

  /// Bearers the fake server will accept (the ones it issued).
  late Set<String> issuedBearers;

  /// How the refresh endpoint answers. Default: definitive rejection.
  late Future<http.Response> Function(http.Request) refreshResponder;

  http.Request? lastRequestTo(String pathFragment) {
    for (final r in requests.reversed) {
      if (r.url.path.contains(pathFragment)) return r;
    }
    return null;
  }

  Map<String, dynamic> loginPayload() => {
        'access_token': _freshAccess,
        'refresh_token': _freshRefresh,
        'user': 'surveyor@example.com',
        'full_name': 'Surveyor',
        'roles': ['Surveyor'],
      };

  setUp(() async {
    store = <String, String>{'frappe_base_url': 'http://x'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, (call) async {
      final args =
          (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
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

    requests = [];
    issuedBearers = {};
    refreshResponder =
        (req) async => _json({'exc_type': 'AuthenticationError'}, 401);

    final server = MockClient((req) async {
      requests.add(req);
      // Frappe validates an Authorization header before running any method,
      // guest-allowed or not.
      final authz = req.headers['Authorization'];
      if (authz != null) {
        final ok = authz.startsWith('Bearer ') &&
            issuedBearers.contains(authz.substring('Bearer '.length));
        if (!ok) return _json({'exc_type': 'AuthenticationError'}, 401);
      }
      final path = req.url.path;
      if (path.contains('mobile_auth.refresh_token')) {
        return refreshResponder(req);
      }
      if (path.contains('mobile_auth.login') ||
          path.contains('mobile_auth.verify_login_otp')) {
        issuedBearers.add(_freshAccess);
        return _json({'message': loginPayload(), ...loginPayload()}, 200);
      }
      if (authz == null) return _json({'exc_type': 'PermissionError'}, 403);
      return _json({'message': 'ok'}, 200);
    });

    db = await AppDatabase.inMemoryDatabase();
    // RestHelper's 401 → refresh hook, wired the way AuthService.initialize
    // wires it in production (forTesting does not wire it on its own).
    client = FrappeClient(
      'http://x',
      httpClient: server,
      onTokenExpired: () => auth.debugTryRefreshMobileAuthToken(),
    );
    auth = AuthService.forTesting(client, database: db);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(storageChannel, null);
    await db.close();
  });

  Future<void> seedRestoredTokenRow() => db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: _deadAccess,
          refreshToken: _deadRefresh,
          user: 'surveyor@example.com',
          fullName: 'Surveyor',
          createdAt: 1,
        ),
      );

  group('SDK_LOGIN_SENDS_NO_STORED_CREDENTIAL', () {
    test('login sends no Authorization or sid with a bearer held', () async {
      await seedRestoredTokenRow();
      expect(await auth.restoreSession(), isTrue,
          reason: 'precondition: restore loads the token row into the bearer');

      try {
        await auth.login('surveyor@example.com', 'typed-by-user');
      } catch (_) {
        // The outcome under test is the request shape, asserted below.
      }

      final req = lastRequestTo('mobile_auth.login');
      expect(req, isNotNull, reason: 'login must reach mobile_auth.login');
      expect(req!.headers['Authorization'], isNull,
          reason: 'the sign-in request must not carry the stored bearer');
      expect(req.headers['Cookie'], isNot(contains('sid=')),
          reason: 'the sign-in request must not carry a stored sid');
    });

    test('login sends no sid cookie or API key when those are held', () async {
      client.rest.setSessionCookie('stale-sid');
      try {
        await auth.login('surveyor@example.com', 'typed-by-user');
      } catch (_) {}
      var req = lastRequestTo('mobile_auth.login');
      expect(req, isNotNull);
      expect(req!.headers['Cookie'], isNull,
          reason: 'no stored sid on the sign-in request');

      client.rest.clearSession();
      client.rest.setApiKey('stale-key', 'stale-secret');
      requests.clear();
      try {
        await auth.login('surveyor@example.com', 'typed-by-user');
      } catch (_) {}
      req = lastRequestTo('mobile_auth.login');
      expect(req, isNotNull);
      expect(req!.headers['Authorization'], isNull,
          reason: 'no stored API key on the sign-in request');
    });

    test('successful login sets the new bearer', () async {
      await seedRestoredTokenRow();
      await auth.restoreSession();

      final info = await auth.login('surveyor@example.com', 'typed-by-user');
      expect(info['user'], 'surveyor@example.com');
      expect(auth.isAuthenticated, isTrue);

      await client.rest.get('/api/method/frappe.auth.get_logged_user');
      expect(
        lastRequestTo('frappe.auth.get_logged_user')!.headers['Authorization'],
        'Bearer $_freshAccess',
        reason: 'the token login returned is the bearer for later requests',
      );
    });
  });

  group('SDK_OTP_LOGIN_SENDS_NO_STORED_CREDENTIAL', () {
    test('verifyLoginOtp sends no stored credential', () async {
      await seedRestoredTokenRow();
      expect(await auth.restoreSession(), isTrue);

      try {
        await auth.verifyLoginOtp('tmp-1', '123456');
      } catch (_) {}

      final req = lastRequestTo('mobile_auth.verify_login_otp');
      expect(req, isNotNull);
      expect(req!.headers['Authorization'], isNull,
          reason: 'the OTP sign-in request must not carry the stored bearer');
      expect(req.headers['Cookie'], isNot(contains('sid=')));
    });
  });

  group('SDK_REJECTED_REFRESH_CLEARS_BEARER', () {
    test('definitive refresh rejection: next request has no Authorization',
        () async {
      await seedRestoredTokenRow();
      expect(await auth.restoreSession(), isTrue);

      // A 401 on an ordinary authenticated call triggers the refresh, which
      // the server definitively rejects.
      await expectLater(
        client.rest.get('/api/method/frappe.auth.get_logged_user'),
        throwsA(anything),
      );
      expect(await db.authTokenDao.getCurrentToken(), isNull,
          reason: 'the dead token row is deleted');
      expect(auth.isAuthenticated, isFalse);

      requests.clear();
      try {
        await client.rest.get('/api/method/frappe.client.get_count');
      } catch (_) {}
      final next = lastRequestTo('frappe.client.get_count');
      expect(next, isNotNull);
      expect(next!.headers['Authorization'], isNull,
          reason: 'a token the SDK has declared dead must not be sent again');
    });

    test('OAuth fallback failure clears the bearer', () async {
      // No mobile-auth row and no OAuth refresh token: the refresh falls
      // through to the OAuth path, which fails and de-authenticates.
      client.rest.setBearerToken(_deadAccess);

      await expectLater(
        client.rest.get('/api/method/frappe.auth.get_logged_user'),
        throwsA(anything),
      );
      expect(auth.isAuthenticated, isFalse);

      requests.clear();
      try {
        await client.rest.get('/api/method/frappe.client.get_count');
      } catch (_) {}
      expect(lastRequestTo('frappe.client.get_count')!.headers['Authorization'],
          isNull);
    });
  });

  group('SDK_TRANSIENT_REFRESH_KEEPS_BEARER', () {
    test('transient refresh failure keeps bearer and row', () async {
      await seedRestoredTokenRow();
      expect(await auth.restoreSession(), isTrue);
      refreshResponder =
          (req) async => _json({'exception': 'ServiceUnavailable'}, 503);

      await expectLater(
        client.rest.get('/api/method/frappe.auth.get_logged_user'),
        throwsA(anything),
      );

      expect(await db.authTokenDao.getCurrentToken(), isNotNull,
          reason: 'a transient failure never wipes the row');
      expect(auth.isAuthenticated, isTrue);

      requests.clear();
      try {
        await client.rest.get('/api/method/frappe.client.get_count');
      } catch (_) {}
      expect(lastRequestTo('frappe.client.get_count')!.headers['Authorization'],
          'Bearer $_deadAccess',
          reason: 'the bearer is kept so a later retry can refresh again');
    });
  });

  group('SDK_SIGN_IN_AFTER_DEAD_RESTORED_TOKEN_SUCCEEDS', () {
    test('restored dead token → 401 → rejected refresh → login succeeds',
        () async {
      // The restored-backup state: a token row the server never issued.
      await seedRestoredTokenRow();
      expect(await auth.restoreSession(), isTrue);

      // Background sync's first authenticated call: 401, refresh rejected.
      await expectLater(
        client.rest.get('/api/method/frappe.auth.get_logged_user'),
        throwsA(anything),
      );
      expect(auth.isAuthenticated, isFalse,
          reason: 'precondition: splash now routes to sign-in');

      // The user signs in with valid credentials.
      final info = await auth.login('surveyor@example.com', 'valid-password');

      expect(info['user'], 'surveyor@example.com');
      expect(auth.isAuthenticated, isTrue);
    });
  });
}
