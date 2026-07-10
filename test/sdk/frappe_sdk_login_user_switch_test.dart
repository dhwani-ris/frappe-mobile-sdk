// Tests for the SWF-2026-64870 login data-isolation guard in FrappeSDK:
// `_isDifferentUser`, `_persistedDeviceUser`, `_wipeIfUserSwitched`, and the
// hardened `_setSessionUserFromLoginResponse`.
//
// These four helpers are private to frappe_sdk.dart and are not reachable
// directly from a test file, nor are they exposed via any existing
// @visibleForTesting seam. Per the fix's own design they are exercised
// exclusively through the public `login()` / `verifyLoginOtp()` entry
// points, so that is what these tests drive.
//
// `FrappeSDK.forTesting` wires a *real* `FrappeClient(baseUrl)` (no
// injectable httpClient), so a real (but fully local, offline, in-process)
// HTTP server stands in for the Frappe backend — see `_FakeAuthServer`
// below. This is not a mock of the SDK; it is a mock of the network peer,
// exactly the seam the SDK itself is designed to talk to.
//
// `_wipeIfUserSwitched` calls the *static* `AppDatabase.clearAllData()`,
// which routes through `AppDatabase.getInstance()` (the process-wide
// singleton) rather than through whatever `AppDatabase` instance a test
// constructs by hand. `AppDatabase.inMemoryDatabase()` deliberately does
// NOT register itself as that singleton (see its doc comment), so tests
// built on it can never observe a real wipe. To get a faithful test of the
// actual wipe mechanics, this file uses `AppDatabase.getInstance()` itself
// (backed by `sqflite_common_ffi`, which needs no platform channels) so our
// `db` reference IS the same instance `clearAllData()` operates on — the
// same relationship production code has. This creates a small on-disk file
// under `.dart_tool/sqflite_common_ffi/databases/` (gitignored); it is
// wiped clean at the start of every test and best-effort deleted at the end
// of the suite.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
import 'package:frappe_mobile_sdk/src/models/session_user.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

/// Minimal in-process stand-in for the Frappe backend's `mobile_auth.login`
/// / `mobile_auth.verify_login_otp` endpoints. Real HTTP over loopback —
/// no mocking of `http.Client` internals required.
class _FakeAuthServer {
  final HttpServer _server;
  Map<String, dynamic> Function(Map<String, dynamic> args)? onLogin;
  Map<String, dynamic> Function(Map<String, dynamic> args)? onVerifyOtp;
  int loginCalls = 0;
  int verifyOtpCalls = 0;

  _FakeAuthServer._(this._server) {
    _server.listen(_handle);
  }

  static Future<_FakeAuthServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeAuthServer._(server);
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    final bodyStr = await utf8.decoder.bind(request).join();
    Map<String, dynamic> args = <String, dynamic>{};
    if (bodyStr.isNotEmpty) {
      final decoded = jsonDecode(bodyStr);
      if (decoded is Map<String, dynamic>) args = decoded;
    }

    Map<String, dynamic>? response;
    if (request.uri.path == '/api/method/mobile_auth.login') {
      loginCalls++;
      response = onLogin?.call(args);
    } else if (request.uri.path ==
        '/api/method/mobile_auth.verify_login_otp') {
      verifyOtpCalls++;
      response = onVerifyOtp?.call(args);
    }

    request.response.headers.contentType = ContentType.json;
    if (response == null) {
      request.response.statusCode = 404;
      request.response.write(jsonEncode({'exc': 'no handler configured'}));
    } else {
      request.response.statusCode = 200;
      request.response.write(jsonEncode(response));
    }
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// Builds a login/OTP response shaped like the real backend. Always carries
/// `offline_enabled: true` so it matches `FrappeSDK.forTesting`'s default
/// OfflineMode and `_applyOfflineFlag` sees no direction change (keeps the
/// test focused on the wipe guard instead of the unrelated offline-mode
/// transition machinery).
Map<String, dynamic> _response({
  required String user,
  String accessToken = 'access-tok',
  String refreshToken = 'refresh-tok',
  String? fullName,
  List<Map<String, dynamic>> mobileFormNames = const [],
}) => {
  'access_token': accessToken,
  'refresh_token': refreshToken,
  'user': user,
  'full_name': fullName ?? user,
  'roles': <String>[],
  'permissions': null,
  'mobile_form_names': mobileFormNames,
  'offline_enabled': true,
};

const _dbAppName = 'swf64870_wipe_switch_test';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDownAll(() async {
    // Best-effort cleanup of the on-disk probe DB this suite creates.
    try {
      final file = File(
        '.dart_tool/sqflite_common_ffi/databases/${_dbAppName}_frappe.db',
      );
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Non-fatal — stray file under a gitignored dir at worst.
    }
  });

  late AppDatabase db;
  late _FakeAuthServer server;
  late FrappeSDK sdk;

  setUp(() async {
    // Same instance `AppDatabase.clearAllData()` (called by the SDK's wipe
    // guard) operates on — see file header for why this must NOT be
    // `inMemoryDatabase()`.
    db = await AppDatabase.getInstance(appName: _dbAppName);
    await AppDatabase.clearAllData();
    server = await _FakeAuthServer.start();
    sdk = FrappeSDK.forTesting(server.baseUrl, db);
  });

  tearDown(() async {
    await sdk.dispose();
    await server.close();
  });

  /// Marker row for "this user's local mirror" — `link_options` is one of
  /// the tables `AppDatabase.clearAllData()` drops+recreates, so its
  /// survival/disappearance is a direct, observable proxy for whether the
  /// wipe fired.
  Future<void> seedLocalMirrorMarker() async {
    await db.rawDatabase.insert('link_options', {
      'doctype': 'Customer',
      'name': 'CUST-1',
      'lastUpdated': 1,
    });
  }

  Future<bool> markerSurvived() async {
    final rows = await db.rawDatabase.rawQuery(
      "SELECT 1 FROM link_options WHERE doctype='Customer' AND name='CUST-1'",
    );
    return rows.isNotEmpty;
  }

  group('_isDifferentUser / _wipeIfUserSwitched via login()', () {
    test(
      'same user re-login (exact match) — no wipe, local mirror survives, '
      'token still updates',
      () async {
        await db.authTokenDao.insertToken(
          AuthTokenEntity(
            accessToken: 'old-tok',
            refreshToken: 'old-refresh',
            user: 'alice@example.com',
            createdAt: 1,
          ),
        );
        await seedLocalMirrorMarker();

        server.onLogin = (_) => _response(
          user: 'alice@example.com',
          accessToken: 'new-tok',
          refreshToken: 'new-refresh',
        );

        final response = await sdk.login('alice@example.com', 'pw');

        expect(response['user'], 'alice@example.com');
        expect(await markerSurvived(), isTrue, reason: 'no wipe expected');
        final token = await db.authTokenDao.getCurrentToken();
        expect(token!.accessToken, 'new-tok');
        expect(token.user, 'alice@example.com');
        expect(sdk.sessionUser?.name, 'alice@example.com');
        expect(server.loginCalls, 1);
      },
    );

    test(
      'same user re-login, different case + surrounding whitespace on the '
      'persisted side — still treated as same user (case/space-insensitive)',
      () async {
        await db.authTokenDao.insertToken(
          AuthTokenEntity(
            accessToken: 'old-tok',
            refreshToken: 'old-refresh',
            user: '  Alice@Example.com  ',
            createdAt: 1,
          ),
        );
        await seedLocalMirrorMarker();

        server.onLogin = (_) => _response(user: 'alice@example.com');

        await sdk.login('alice@example.com', 'pw');

        expect(await markerSurvived(), isTrue, reason: 'no wipe expected');
      },
    );

    test(
      'different user login — previous user local mirror is wiped, new '
      'auth-token row + doctype-meta flags are restored (reapplyLoginResponse)',
      () async {
        await db.authTokenDao.insertToken(
          AuthTokenEntity(
            accessToken: 'alice-tok',
            refreshToken: 'alice-refresh',
            user: 'alice@example.com',
            createdAt: 1,
          ),
        );
        await seedLocalMirrorMarker();
        // Stale meta flag from alice's session — must not survive.
        await db.doctypeMetaDao.insertDoctypeMeta(
          DoctypeMetaEntity(
            doctype: 'AliceForm',
            isMobileForm: true,
            metaJson: '{}',
          ),
        );

        server.onLogin = (_) => _response(
          user: 'bob@example.com',
          accessToken: 'bob-tok',
          refreshToken: 'bob-refresh',
          fullName: 'Bob',
          mobileFormNames: [
            {
              'mobile_workspace_item': 'BobForm',
              'doctype_meta_modifed_at': '2026-01-01 00:00:00',
            },
          ],
        );

        final response = await sdk.login('bob@example.com', 'pw');
        expect(response['user'], 'bob@example.com');

        // Wipe fired: previous user's local mirror is gone.
        expect(await markerSurvived(), isFalse, reason: 'wipe expected');

        // reapplyLoginResponse restored the auth-token row on the CLEAN db.
        final token = await db.authTokenDao.getCurrentToken();
        expect(token, isNotNull);
        expect(token!.user, 'bob@example.com');
        expect(token.accessToken, 'bob-tok');
        expect(token.fullName, 'Bob');

        // Stale meta from alice did not survive the wipe.
        expect(await db.doctypeMetaDao.findByDoctype('AliceForm'), isNull);

        // Bob's mobile-form meta was restored post-wipe with no extra
        // network round-trip.
        final bobMeta = await db.doctypeMetaDao.findByDoctype('BobForm');
        expect(bobMeta, isNotNull);
        expect(bobMeta!.isMobileForm, isTrue);
        expect(bobMeta.serverModifiedAt, '2026-01-01 00:00:00');

        expect(sdk.sessionUser?.name, 'bob@example.com');
        expect(
          server.loginCalls,
          1,
          reason: 'reapplyLoginResponse must not re-hit the network',
        );
      },
    );

    test(
      'fresh install (no persisted device user, no session) — first login '
      'never wipes',
      () async {
        // Clean DB from setUp already has no token / no session user.
        expect(await db.authTokenDao.getCurrentToken(), isNull);
        expect(sdk.sessionUser, isNull);

        await seedLocalMirrorMarker();
        server.onLogin = (_) => _response(user: 'carol@example.com');

        await sdk.login('carol@example.com', 'pw');

        expect(
          await markerSurvived(),
          isTrue,
          reason: 'nothing to switch away from — must not wipe',
        );
        expect(sdk.sessionUser?.name, 'carol@example.com');
      },
    );

    test(
      'login response with a whitespace-only user does not wipe AND clears '
      '(does not retain) a previously-set different session user',
      () async {
        // A previous, unrelated session left a session user populated.
        await sdk.sessionUserService.set(
          const SessionUser(
            name: 'stale@example.com',
            fullName: 'Stale User',
            roles: [],
            userDefaults: {},
            permissions: {},
            extras: {},
          ),
        );
        await db.authTokenDao.insertToken(
          AuthTokenEntity(
            accessToken: 'old-tok',
            refreshToken: 'old-refresh',
            user: 'stale@example.com',
            createdAt: 1,
          ),
        );
        await seedLocalMirrorMarker();

        // AuthService.login() only throws on a null/empty `user`; a
        // whitespace-only string passes that (untrimmed) check but becomes
        // empty after FrappeSDK's trimmed comparison — the exact edge case
        // `_setSessionUserFromLoginResponse` hardens against.
        server.onLogin = (_) => _response(user: '   ');

        await sdk.login('nobody@example.com', 'pw');

        expect(
          sdk.sessionUser,
          isNull,
          reason:
              'must clear, not retain, the previous different-user session',
        );
        expect(
          await markerSurvived(),
          isTrue,
          reason:
              'incoming user is unreadable — must not wipe (cannot tell '
              'who is logging in)',
        );
      },
    );
  });

  group('_isDifferentUser / _wipeIfUserSwitched via verifyLoginOtp()', () {
    test(
      'different user via OTP triggers the same wipe guard as login()',
      () async {
        await db.authTokenDao.insertToken(
          AuthTokenEntity(
            accessToken: 'alice-tok',
            refreshToken: 'alice-refresh',
            user: 'alice@example.com',
            createdAt: 1,
          ),
        );
        await seedLocalMirrorMarker();

        server.onVerifyOtp = (_) => _response(
          user: 'dave@example.com',
          accessToken: 'dave-tok',
          refreshToken: 'dave-refresh',
        );

        final response = await sdk.verifyLoginOtp('tmp-1', '123456');
        expect(response['user'], 'dave@example.com');

        expect(await markerSurvived(), isFalse, reason: 'wipe expected');
        final token = await db.authTokenDao.getCurrentToken();
        expect(token!.user, 'dave@example.com');
        expect(sdk.sessionUser?.name, 'dave@example.com');
        expect(server.verifyOtpCalls, 1);
      },
    );

    test('same user via OTP does not wipe', () async {
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'alice-tok',
          refreshToken: 'alice-refresh',
          user: 'alice@example.com',
          createdAt: 1,
        ),
      );
      await seedLocalMirrorMarker();

      server.onVerifyOtp = (_) => _response(user: 'alice@example.com');

      await sdk.verifyLoginOtp('tmp-1', '123456');

      expect(await markerSurvived(), isTrue, reason: 'no wipe expected');
    });
  });
}
