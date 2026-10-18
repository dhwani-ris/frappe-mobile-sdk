import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/attachment_service.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/api/client_info.dart';
import 'package:frappe_mobile_sdk/src/api/oauth2_helper.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/auth_service.dart';

/// Mirror of `parse_client_info` in Frappe Mobile Control
/// (`mobile_control/api/helpers/client_log.py`): split on `;`, partition each
/// part on the first `=`, skip parts without one, lower-case + strip the key,
/// strip the value, keep known keys only, split `ver` on the first `+` into
/// version and build, and clip every value to 140 characters.
Map<String, String?> parseLikeServer(String header) {
  const keyMap = {
    'app': 'app_name',
    'ver': 'app_version',
    'platform': 'platform',
    'os': 'os_version',
    'model': 'device_model',
    'device': 'device_id',
  };
  final info = <String, String?>{};
  for (final part in header.split(';')) {
    final i = part.indexOf('=');
    if (i < 0) continue;
    final field = keyMap[part.substring(0, i).trim().toLowerCase()];
    if (field != null) info[field] = part.substring(i + 1).trim();
  }
  final version = info['app_version'];
  if (version != null && version.contains('+')) {
    final i = version.indexOf('+');
    info['app_version'] = version.substring(0, i);
    info['build_number'] = version.substring(i + 1);
  }
  return info.map((k, v) {
    if (v == null) return MapEntry(k, null);
    final clipped = v.length > 140 ? v.substring(0, 140) : v;
    return MapEntry(k, clipped.isEmpty ? null : clipped);
  });
}

const _info = ClientInfo(
  appName: 'Field App',
  appVersion: '2.9.0+72',
  platform: 'android',
  osVersion: 'Android 14',
  deviceId: '6f1c2a4e-0000-4000-8000-000000000001',
);

const _expectedHeader =
    'app=Field App;ver=2.9.0+72;platform=android;os=Android 14;'
    'device=6f1c2a4e-0000-4000-8000-000000000001';

http.Response _ok(Object body) => http.Response(jsonEncode(body), 200);

void main() {
  group('ClientInfo header format', () {
    test('exact string, in key order, empty fields left out', () {
      expect(_info.toHeaderValue(), _expectedHeader);
      expect(_info.toHeaders(), {'X-Client-Info': _expectedHeader});
    });

    test('parses with the server rules into the right fields', () {
      final parsed = parseLikeServer(_info.toHeaderValue()!);
      expect(parsed, {
        'app_name': 'Field App',
        'app_version': '2.9.0',
        'build_number': '72',
        'platform': 'android',
        'os_version': 'Android 14',
        'device_id': '6f1c2a4e-0000-4000-8000-000000000001',
      });
    });

    test('model is sent when given', () {
      const info = ClientInfo(deviceModel: 'Pixel 8', deviceId: 'd1');
      expect(info.toHeaderValue(), 'model=Pixel 8;device=d1');
      expect(parseLikeServer(info.toHeaderValue()!)['device_model'], 'Pixel 8');
    });

    test('nothing to send gives null and no headers', () {
      const info = ClientInfo(appName: ' ;= ', deviceId: '');
      expect(info.toHeaderValue(), isNull);
      expect(info.toHeaders(), isEmpty);
    });
  });

  group('ClientInfo.sanitize', () {
    test('separators, newlines and control characters become spaces', () {
      expect(ClientInfo.sanitize('a;b=c\r\nd\te'), 'a b c d e');
    });

    test('non-ASCII is replaced so the header stays valid', () {
      expect(ClientInfo.sanitize('Café Ñ app'), 'Caf app');
    });

    test('clips to 140 characters', () {
      final long = 'x' * 300;
      expect(ClientInfo.sanitize(long)!.length, 140);
    });

    test('blank becomes null', () {
      expect(ClientInfo.sanitize(null), isNull);
      expect(ClientInfo.sanitize('  \n '), isNull);
    });

    test('a hostile value cannot inject a second field', () {
      const info = ClientInfo(
        appName: 'evil;device=spoofed',
        deviceId: 'real-device',
      );
      final parsed = parseLikeServer(info.toHeaderValue()!);
      expect(parsed['device_id'], 'real-device');
      expect(parsed['app_name'], 'evil device spoofed');
    });

    test('every value survives the server parser unchanged', () {
      final info = ClientInfo(
        appName: 'A' * 200,
        appVersion: '1.0.0',
        platform: 'ios',
        osVersion: 'Version 17.0 (Build 21A329)',
        deviceId: 'id',
      );
      final parsed = parseLikeServer(info.toHeaderValue()!);
      expect(parsed['app_name'], 'A' * 140);
      expect(parsed['os_version'], 'Version 17.0 (Build 21A329)');
    });
  });

  test('FrappeSDK sends client info by default and can opt out', () {
    final sdk = FrappeSDK(baseUrl: 'http://x');
    expect(sdk.sendClientInfo, isTrue);
    expect(sdk.clientAppName, isNull);
    final optedOut = FrappeSDK(
      baseUrl: 'http://x',
      sendClientInfo: false,
      clientAppName: 'Custom',
      clientAppVersion: '1.2.3',
    );
    expect(optedOut.sendClientInfo, isFalse);
    expect(optedOut.clientAppName, 'Custom');
    expect(optedOut.clientAppVersion, '1.2.3');
  });

  group('ClientInfo.collect', () {
    Future<PackageInfo> pkg() async => PackageInfo(
      appName: 'Field App',
      packageName: 'org.example.field',
      version: '2.9.0',
      buildNumber: '72',
    );

    test('reads name and version+build from package info', () async {
      final info = await ClientInfo.collect(
        deviceId: 'd1',
        packageInfoLoader: pkg,
      );
      expect(info.appName, 'Field App');
      expect(info.appVersion, '2.9.0+72');
      expect(info.platform, Platform.operatingSystem);
      expect(info.osVersion, Platform.operatingSystemVersion);
      expect(info.deviceModel, isNull);
      expect(info.deviceId, 'd1');
    });

    test('host overrides win and skip the package lookup', () async {
      var called = false;
      final info = await ClientInfo.collect(
        deviceId: 'd1',
        appName: 'Custom',
        appVersion: '9.9.9',
        packageInfoLoader: () async {
          called = true;
          return pkg();
        },
      );
      expect(called, isFalse);
      expect(info.appName, 'Custom');
      expect(info.appVersion, '9.9.9');
    });

    test('a failing package lookup leaves app fields out', () async {
      final info = await ClientInfo.collect(
        deviceId: 'd1',
        platform: 'android',
        osVersion: '14',
        packageInfoLoader: () async => throw StateError('no plugin'),
      );
      expect(info.toHeaderValue(), 'platform=android;os=14;device=d1');
    });
  });

  group('RestHelper sends X-Client-Info', () {
    late List<http.BaseRequest> seen;
    late RestHelper rest;

    setUp(() {
      seen = [];
      rest = RestHelper(
        'http://x',
        client: MockClient((req) async {
          seen.add(req);
          return _ok({'message': 'ok'});
        }),
      )..setClientInfo(_info);
    });

    test('on authenticated and public calls of every method', () async {
      rest.setBearerToken('AT');
      await rest.get('/api/resource/ToDo');
      await rest.post('/api/resource/ToDo', body: {'a': 1});
      await rest.put('/api/resource/ToDo/1', body: {'a': 2});
      await rest.delete('/api/resource/ToDo/1');
      await rest.callPublic('mobile_auth.refresh_token', args: {'r': 't'});
      await rest.getPublic('/api/method/ping');
      expect(seen, hasLength(6));
      for (final req in seen) {
        expect(req.headers['X-Client-Info'], _expectedHeader);
      }
    });

    test('survives clearSession and is exposed for private files', () async {
      rest.clearSession();
      await rest.get('/api/method/ping');
      expect(seen.single.headers['X-Client-Info'], _expectedHeader);
      expect(rest.requestHeaders['X-Client-Info'], _expectedHeader);
      expect(rest.clientHeaders, {'X-Client-Info': _expectedHeader});
    });

    test('not sent when unset or cleared', () async {
      rest.setClientInfo(null);
      await rest.get('/api/method/ping');
      expect(seen.single.headers.containsKey('X-Client-Info'), isFalse);
      expect(rest.clientHeaders, isEmpty);
    });
  });

  test('upload carries X-Client-Info', () async {
    http.BaseRequest? seen;
    final client = MockClient.streaming((req, stream) async {
      seen = req;
      await stream.drain<void>();
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'message': {'file_url': '/files/a.txt'},
            }),
          ),
        ),
        200,
      );
    });
    final rest = RestHelper('http://x', client: client)..setClientInfo(_info);
    final dir = await Directory.systemTemp.createTemp('client-info-');
    final file = File('${dir.path}/a.txt')..writeAsStringSync('hi');
    await AttachmentService(rest).uploadFile(file, fileName: 'a.txt');
    expect(seen!.headers['X-Client-Info'], _expectedHeader);
  });

  group('auth calls carry X-Client-Info', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    test('login and OTP', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final db = await AppDatabase.inMemoryDatabase();
      addTearDown(db.close);
      final seen = <String, String?>{};
      final client = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          seen[req.url.path] = req.headers['X-Client-Info'];
          if (req.url.path.endsWith('send_login_otp')) {
            return _ok({'tmp_id': 'T1'});
          }
          return _ok({
            'access_token': 'AT',
            'refresh_token': 'RT',
            'user': 'user@example.com',
          });
        }),
      );
      client.rest.setClientInfo(_info);
      final auth = AuthService.forTesting(client, database: db);

      await auth.login('user@example.com', 'secret');
      await auth.sendLoginOtp('9000000000');

      expect(seen, {
        '/api/method/mobile_auth.login': _expectedHeader,
        '/api/method/mobile_auth.send_login_otp': _expectedHeader,
      });
    });

    test('OAuth token refresh sends the headers it is given', () async {
      http.BaseRequest? seen;
      await http.runWithClient(
        () => OAuth2Helper.refreshToken(
          baseUrl: 'http://x',
          clientId: 'c',
          refreshToken: 'r',
          headers: _info.toHeaders(),
        ),
        () => MockClient((req) async {
          seen = req;
          return _ok({'access_token': 'AT'});
        }),
      );
      expect(seen!.headers['X-Client-Info'], _expectedHeader);
      expect(
        seen!.headers['Content-Type'],
        startsWith('application/x-www-form-urlencoded'),
      );
    });
  });
}
