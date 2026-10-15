// Mobile-auth tokens must live in secure storage, never in the plain SQLite
// `auth_tokens` row: a copy of the database file must not carry a live
// credential. These tests pin where each write lands, the one-time migration
// of rows written by older SDK versions, and that logout clears both stores.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

const _accessKey = 'frappe_mobile_access_token';
const _refreshKey = 'frappe_mobile_refresh_token';

int _agedCreatedAt() =>
    DateTime.now().subtract(const Duration(hours: 25)).millisecondsSinceEpoch;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late Map<String, String> secure;
  late List<String?> authHeaders;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
    secure = <String, String>{'frappe_base_url': 'http://x'};
    FlutterSecureStorage.setMockInitialValues(secure);
    authHeaders = <String?>[];
  });
  tearDown(() async => db.close());

  /// A client answering login, refresh and logout, recording the
  /// Authorization header of every other request.
  FrappeClient client({int refreshStatus = 200}) => FrappeClient(
    'http://x',
    httpClient: MockClient((req) async {
      switch (req.url.path) {
        case '/api/method/mobile_auth.login':
          return http.Response(
            jsonEncode({
              'access_token': 'AT-login',
              'refresh_token': 'RT-login',
              'user': 'field@example.org',
              'full_name': 'Field Worker',
            }),
            200,
          );
        case '/api/method/mobile_auth.refresh_token':
          if (refreshStatus != 200) {
            return http.Response(
              jsonEncode({'message': 'Invalid or expired refresh token'}),
              refreshStatus,
            );
          }
          return http.Response(
            jsonEncode({
              'access_token': 'AT-refreshed',
              'refresh_token': 'RT-refreshed',
            }),
            200,
          );
        default:
          authHeaders.add(req.headers['Authorization']);
          return http.Response('{}', 200);
      }
    }),
  );

  Future<void> insertLegacyRow({int? createdAt}) => db.authTokenDao.insertToken(
    AuthTokenEntity(
      accessToken: 'AT-legacy',
      refreshToken: 'RT-legacy',
      user: 'field@example.org',
      fullName: 'Field Worker',
      createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch,
    ),
  );

  test('login stores tokens in secure storage, not in the database', () async {
    final auth = AuthService.forTesting(client(), database: db);

    await auth.login('field@example.org', 'pw');

    expect(secure[_accessKey], 'AT-login');
    expect(secure[_refreshKey], 'RT-login');
    final row = await db.authTokenDao.getCurrentToken();
    expect(row, isNotNull);
    expect(row!.accessToken, isEmpty);
    expect(row.refreshToken, isEmpty);
    expect(row.user, 'field@example.org');
    expect(row.fullName, 'Field Worker');
    expect(auth.isAuthenticated, isTrue);
  });

  test('restoreSession reads the token back from secure storage', () async {
    final c = client();
    await AuthService.forTesting(
      c,
      database: db,
    ).login('field@example.org', 'pw');

    final restoredClient = client();
    final auth = AuthService.forTesting(restoredClient, database: db);
    expect(await auth.restoreSession(isOnline: false), isTrue);
    await restoredClient.rest.call('ping');

    expect(authHeaders.last, 'Bearer AT-login');
    expect(auth.currentUserInfo?.email, 'field@example.org');
  });

  test('a refreshed token is stored in secure storage only', () async {
    await db.authTokenDao.insertToken(
      AuthTokenEntity(
        accessToken: '',
        refreshToken: '',
        user: 'field@example.org',
        createdAt: _agedCreatedAt(),
      ),
    );
    secure[_accessKey] = 'AT-old';
    secure[_refreshKey] = 'RT-old';
    final auth = AuthService.forTesting(client(), database: db);

    expect(await auth.restoreSession(isOnline: true), isTrue);

    expect(secure[_accessKey], 'AT-refreshed');
    expect(secure[_refreshKey], 'RT-refreshed');
    final row = await db.authTokenDao.getCurrentToken();
    expect(row!.accessToken, isEmpty);
    expect(row.refreshToken, isEmpty);
  });

  group('migration of rows written by older SDK versions', () {
    test('moves the token to secure storage and blanks the row', () async {
      await insertLegacyRow();
      final c = client();
      final auth = AuthService.forTesting(c, database: db);

      expect(await auth.restoreSession(isOnline: false), isTrue);

      expect(secure[_accessKey], 'AT-legacy');
      expect(secure[_refreshKey], 'RT-legacy');
      final row = await db.authTokenDao.getCurrentToken();
      expect(row!.accessToken, isEmpty);
      expect(row.refreshToken, isEmpty);
      expect(row.user, 'field@example.org');
      expect(row.fullName, 'Field Worker');

      await c.rest.call('ping');
      expect(authHeaders.last, 'Bearer AT-legacy');
    });

    test('the migrated refresh token is the one redeemed', () async {
      await insertLegacyRow(createdAt: _agedCreatedAt());
      String? redeemed;
      final c = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          redeemed = jsonDecode(req.body)['refresh_token'] as String?;
          return http.Response(
            jsonEncode({'access_token': 'AT-new', 'refresh_token': 'RT-new'}),
            200,
          );
        }),
      );
      final auth = AuthService.forTesting(c, database: db);

      expect(await auth.restoreSession(isOnline: true), isTrue);

      expect(redeemed, 'RT-legacy');
      expect(secure[_refreshKey], 'RT-new');
      expect((await db.authTokenDao.getCurrentToken())!.refreshToken, isEmpty);
    });

    test('a token left in the row replaces a stale secure copy', () async {
      // Only an older SDK writes tokens into the row, so a non-empty row is
      // the newest token on the device (e.g. after a downgrade and upgrade).
      await insertLegacyRow();
      secure[_accessKey] = 'AT-stale';
      secure[_refreshKey] = 'RT-stale';
      final auth = AuthService.forTesting(client(), database: db);

      await auth.restoreSession(isOnline: false);

      expect(secure[_accessKey], 'AT-legacy');
      expect(secure[_refreshKey], 'RT-legacy');
    });
  });

  test(
    'logout clears the token from secure storage and the database',
    () async {
      final auth = AuthService.forTesting(client(), database: db);
      await auth.login('field@example.org', 'pw');

      await auth.logout(clearDatabase: false);

      expect(secure.containsKey(_accessKey), isFalse);
      expect(secure.containsKey(_refreshKey), isFalse);
      expect(await db.authTokenDao.getCurrentToken(), isNull);
      expect(await auth.restoreSession(isOnline: false), isFalse);
    },
  );

  test('a definitively rejected refresh clears secure storage too', () async {
    await db.authTokenDao.insertToken(
      AuthTokenEntity(
        accessToken: '',
        refreshToken: '',
        user: 'field@example.org',
        createdAt: _agedCreatedAt(),
      ),
    );
    secure[_accessKey] = 'AT-old';
    secure[_refreshKey] = 'RT-dead';
    final auth = AuthService.forTesting(
      client(refreshStatus: 417),
      database: db,
    );

    expect(await auth.restoreSession(isOnline: true), isFalse);

    expect(auth.expiredSessionEmail, 'field@example.org');
    expect(secure.containsKey(_accessKey), isFalse);
    expect(secure.containsKey(_refreshKey), isFalse);
    expect(await db.authTokenDao.getCurrentToken(), isNull);
  });
}
