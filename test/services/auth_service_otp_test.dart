// Coverage for issue #138 (mobile OTP login): `AuthService.sendLoginOtp` and
// `AuthService.verifyLoginOtp` against mocked `mobile_auth.send_login_otp` /
// `mobile_auth.verify_login_otp` responses, plus the full
// trigger -> verify -> authenticated-call flow end to end.
//
// Mirrors the mocking conventions in auth_service_wiring_test.dart: an
// in-memory sqflite database, `AuthService.forTesting`, and
// `package:http/testing.dart`'s `MockClient` injected into `FrappeClient`.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
  });
  tearDown(() async => db.close());

  group('sendLoginOtp', () {
    test('posts mobile_no to mobile_auth.send_login_otp and returns the '
        'tmp_id/mobile_no/prompt payload', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          expect(req.method, 'POST');
          expect(req.url.path, '/api/method/mobile_auth.send_login_otp');
          expect(jsonDecode(req.body), {'mobile_no': '9876543210'});
          return http.Response(
            jsonEncode({
              'message': 'OTP sent successfully',
              'tmp_id': 'tmp-abc123',
              'mobile_no': '987XXXXXXX',
              'prompt': 'Enter verification code sent to 987XXXXXXX',
            }),
            200,
          );
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      final response = await auth.sendLoginOtp('9876543210');

      expect(response['tmp_id'], 'tmp-abc123');
      expect(response['mobile_no'], '987XXXXXXX');
      expect(response['message'], 'OTP sent successfully');
      // Sending the OTP must not authenticate the client by itself.
      expect(auth.isAuthenticated, isFalse);
    });

    test('throws when AuthService has not been initialized/wired to a '
        'client', () async {
      final auth = AuthService();

      await expectLater(auth.sendLoginOtp('9876543210'), throwsException);
    });

    test('propagates a rate-limit (429) rejection from the server', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(jsonEncode({'message': 'slow down'}), 429);
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      await expectLater(auth.sendLoginOtp('9876543210'), throwsA(anything));
      expect(auth.isAuthenticated, isFalse);
    });

    test(
      'propagates a 404 when no user exists for the mobile number',
      () async {
        final client = FrappeClient(
          'http://x',
          httpClient: MockClient((req) async {
            return http.Response(
              jsonEncode({'message': 'No user found with this Phone number.'}),
              404,
            );
          }),
        );
        final auth = AuthService.forTesting(client, database: db);

        await expectLater(auth.sendLoginOtp('0000000000'), throwsA(anything));
      },
    );
  });

  group('verifyLoginOtp', () {
    Map<String, dynamic> successBody({
      String accessToken = 'AT-otp-1',
      String refreshToken = 'RT-otp-1',
      String user = 'farmer@example.com',
    }) => {
      'message': 'Logged In',
      'user': user,
      'full_name': 'Example Farmer',
      'language': 'en',
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'offline_enabled': true,
      'roles': ['Mobile User', 'Farmer'],
      'mobile_form_names': [
        {'mobile_workspace_item': 'Visit Log', 'group_name': 'Field'},
      ],
    };

    test('posts tmp_id/otp to mobile_auth.verify_login_otp, stores the '
        'token pair, and authenticates the client', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          expect(req.url.path, '/api/method/mobile_auth.verify_login_otp');
          expect(jsonDecode(req.body), {
            'tmp_id': 'tmp-abc123',
            'otp': '123456',
          });
          return http.Response(jsonEncode(successBody()), 200);
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      final response = await auth.verifyLoginOtp('tmp-abc123', '123456');

      expect(response['access_token'], 'AT-otp-1');
      expect(auth.isAuthenticated, isTrue);
      expect(auth.roles, containsAll(['Mobile User', 'Farmer']));
      expect(auth.language, 'en');
      expect(auth.currentUserInfo?.email, 'farmer@example.com');
      expect(auth.currentUserInfo?.fullName, 'Example Farmer');

      final stored = await db.authTokenDao.getCurrentToken();
      expect(stored, isNotNull);
      expect(stored!.accessToken, 'AT-otp-1');
      expect(stored.refreshToken, 'RT-otp-1');
      expect(stored.user, 'farmer@example.com');

      final meta = await db.doctypeMetaDao.findByDoctype('Visit Log');
      expect(meta, isNotNull);
      expect(meta!.isMobileForm, isTrue);
      expect(meta.groupName, 'Field');
    });

    test(
      'the stored access_token is wired as the Bearer header on the next '
      'authenticated call (trigger -> verify -> authenticated-call flow)',
      () async {
        String? capturedAuthHeader;
        final client = FrappeClient(
          'http://x',
          httpClient: MockClient((req) async {
            if (req.url.path == '/api/method/mobile_auth.send_login_otp') {
              return http.Response(
                jsonEncode({'tmp_id': 'tmp-xyz', 'mobile_no': '987XXXXXXX'}),
                200,
              );
            }
            if (req.url.path == '/api/method/mobile_auth.verify_login_otp') {
              return http.Response(jsonEncode(successBody()), 200);
            }
            // The "authenticated call" that follows OTP login.
            capturedAuthHeader = req.headers['Authorization'];
            return http.Response(jsonEncode({'message': 'ok'}), 200);
          }),
        );
        final auth = AuthService.forTesting(client, database: db);

        final sent = await auth.sendLoginOtp('9876543210');
        expect(sent['tmp_id'], 'tmp-xyz');

        final verified = await auth.verifyLoginOtp(
          sent['tmp_id'] as String,
          '654321',
        );
        expect(verified['access_token'], 'AT-otp-1');
        expect(auth.isAuthenticated, isTrue);

        await client.rest.call('some.whitelisted.method');

        expect(capturedAuthHeader, 'Bearer AT-otp-1');
      },
    );

    test('throws and leaves the client unauthenticated when the database '
        'has not been configured', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(jsonEncode(successBody()), 200);
        }),
      );
      final auth = AuthService.forTesting(client);

      await expectLater(
        auth.verifyLoginOtp('tmp-abc123', '123456'),
        throwsException,
      );
      expect(auth.isAuthenticated, isFalse);
    });

    test('rejects an invalid/expired OTP (400) and does not authenticate '
        'or persist a token', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({'message': 'Invalid OTP or session expired'}),
            400,
          );
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      await expectLater(
        auth.verifyLoginOtp('tmp-abc123', '000000'),
        throwsA(anything),
      );
      expect(auth.isAuthenticated, isFalse);
      expect(await db.authTokenDao.getCurrentToken(), isNull);
    });

    test('rejects a lockout (429) after too many failed attempts', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({'message': 'Too many attempts'}),
            429,
          );
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      await expectLater(
        auth.verifyLoginOtp('tmp-abc123', '111111'),
        throwsA(anything),
      );
      expect(auth.isAuthenticated, isFalse);
    });

    test('throws when the server response is missing access_token', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({'user': 'farmer@example.com', 'refresh_token': 'RT-1'}),
            200,
          );
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      await expectLater(
        auth.verifyLoginOtp('tmp-abc123', '123456'),
        throwsException,
      );
      expect(auth.isAuthenticated, isFalse);
    });

    test('throws when the server response is missing refresh_token', () async {
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          return http.Response(
            jsonEncode({'user': 'farmer@example.com', 'access_token': 'AT-1'}),
            200,
          );
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      await expectLater(
        auth.verifyLoginOtp('tmp-abc123', '123456'),
        throwsException,
      );
      expect(auth.isAuthenticated, isFalse);
    });

    test('a second verifyLoginOtp call updates the existing token row '
        'instead of inserting a duplicate', () async {
      var call = 0;
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          call++;
          return http.Response(
            jsonEncode(
              successBody(accessToken: 'AT-$call', refreshToken: 'RT-$call'),
            ),
            200,
          );
        }),
      );
      final auth = AuthService.forTesting(client, database: db);

      await auth.verifyLoginOtp('tmp-1', '111111');
      await auth.verifyLoginOtp('tmp-2', '222222');

      expect((await db.authTokenDao.getCurrentToken())!.accessToken, 'AT-2');
    });
  });
}
