// Tests for AuthService.reapplyLoginResponse — SWF-2026-64870.
//
// reapplyLoginResponse re-persists an already-completed login/OTP response
// onto the local database with NO network call. It exists so the SDK's
// user-switch data-isolation guard (FrappeSDK._wipeIfUserSwitched) can
// restore the auth-token row + mobile-form doctype-meta flags after
// AppDatabase.clearAllData() wipes them mid-login.
//
// These tests exercise AuthService directly (not through FrappeSDK) so we
// can assert "no network call" precisely via a MockClient that fails the
// test if invoked, and can inspect the DB rows written without any HTTP
// dependency.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/auth_token_entity.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late AuthService authService;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
    // MockClient fails the test if AuthService ever tries to make an HTTP
    // call from reapplyLoginResponse — pinning the "no network call"
    // contract from the doc comment.
    final client = FrappeClient(
      'http://localhost',
      httpClient: MockClient((request) async {
        fail(
          'reapplyLoginResponse must not perform any network call, '
          'but a request was made to ${request.url}',
        );
      }),
    );
    authService = AuthService.forTesting(client, database: db);
  });

  tearDown(() async => db.close());

  Map<String, dynamic> fullResponse({
    String user = 'alice@example.com',
    String accessToken = 'access-1',
    String refreshToken = 'refresh-1',
  }) => {
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'user': user,
    'full_name': 'Alice',
    'mobile_form_names': [
      {
        'mobile_workspace_item': 'Customer',
        'doctype_meta_modifed_at': '2026-01-01 00:00:00',
      },
    ],
  };

  group('reapplyLoginResponse', () {
    test('restores the auth-token row with no network call', () async {
      await authService.reapplyLoginResponse(fullResponse());

      final token = await db.authTokenDao.getCurrentToken();
      expect(token, isNotNull);
      expect(token!.accessToken, 'access-1');
      expect(token.refreshToken, 'refresh-1');
      expect(token.user, 'alice@example.com');
      expect(token.fullName, 'Alice');
    });

    test('marks the incoming mobile_form_names doctype as a mobile form', () async {
      await authService.reapplyLoginResponse(fullResponse());

      final meta = await db.doctypeMetaDao.findByDoctype('Customer');
      expect(meta, isNotNull);
      expect(meta!.isMobileForm, isTrue);
      expect(meta.serverModifiedAt, '2026-01-01 00:00:00');
    });

    test(
      'clears isMobileForm on doctypes NOT in the new mobile_form_names — '
      'the previous user (or previous login) must not leave stale mobile-form '
      'flags for doctypes the new response no longer lists',
      () async {
        // Simulate a stale meta row left behind for a doctype the previous
        // user had access to but the incoming response does not mention.
        await db.doctypeMetaDao.insertDoctypeMeta(
          DoctypeMetaEntity(
            doctype: 'StaleDoctype',
            isMobileForm: true,
            metaJson: '{}',
          ),
        );

        await authService.reapplyLoginResponse(fullResponse());

        final stale = await db.doctypeMetaDao.findByDoctype('StaleDoctype');
        expect(stale, isNotNull);
        expect(
          stale!.isMobileForm,
          isFalse,
          reason:
              'reapplyLoginResponse must flip previously-mobile-form '
              'doctypes off before applying the new response, exactly '
              'like a normal login does',
        );

        final fresh = await db.doctypeMetaDao.findByDoctype('Customer');
        expect(fresh!.isMobileForm, isTrue);
      },
    );

    test('sets isAuthenticated + currentUserInfo like a real login', () async {
      expect(authService.isAuthenticated, isFalse);
      await authService.reapplyLoginResponse(fullResponse());
      expect(authService.isAuthenticated, isTrue);
      expect(authService.currentUserInfo?.email, 'alice@example.com');
      expect(authService.currentUserInfo?.fullName, 'Alice');
    });

    test('replaces an existing auth-token row (update, not duplicate insert)', () async {
      await db.authTokenDao.insertToken(
        AuthTokenEntity(
          accessToken: 'old',
          refreshToken: 'old-r',
          user: 'stale@example.com',
          createdAt: 1,
        ),
      );

      await authService.reapplyLoginResponse(fullResponse(user: 'bob@example.com'));

      final token = await db.authTokenDao.getCurrentToken();
      expect(token!.user, 'bob@example.com');
      expect(token.accessToken, 'access-1');
    });

    test('no-ops (does not touch the DB) when access_token is missing', () async {
      await authService.reapplyLoginResponse({
        'refresh_token': 'r',
        'user': 'alice@example.com',
      });
      expect(await db.authTokenDao.getCurrentToken(), isNull);
      expect(authService.isAuthenticated, isFalse);
    });

    test('no-ops when refresh_token is missing', () async {
      await authService.reapplyLoginResponse({
        'access_token': 'a',
        'user': 'alice@example.com',
      });
      expect(await db.authTokenDao.getCurrentToken(), isNull);
    });

    test('no-ops when user is missing', () async {
      await authService.reapplyLoginResponse({
        'access_token': 'a',
        'refresh_token': 'r',
      });
      expect(await db.authTokenDao.getCurrentToken(), isNull);
    });

    test('no-ops when user is an empty string', () async {
      await authService.reapplyLoginResponse({
        'access_token': 'a',
        'refresh_token': 'r',
        'user': '',
      });
      expect(await db.authTokenDao.getCurrentToken(), isNull);
    });

    test('handles absent mobile_form_names without crashing', () async {
      await authService.reapplyLoginResponse({
        'access_token': 'a',
        'refresh_token': 'r',
        'user': 'alice@example.com',
      });
      final token = await db.authTokenDao.getCurrentToken();
      expect(token!.user, 'alice@example.com');
    });
  });
}
