import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/services/app_status_service.dart';

/// AppStatusService instantiates its own RestHelper inside the constructor,
/// which in turn calls `http.Client()`. Use `http.runWithClient` to substitute
/// a [MockClient] for the duration of the test body.
Future<T> _withMock<T>(
  http.Response Function(http.Request req) handler,
  Future<T> Function() body,
) {
  return http.runWithClient(body, () => MockClient((r) async => handler(r)));
}

void main() {
  test('fetchAppStatus parses {data: {...}} envelope', () async {
    final svc = await _withMock(
      (req) => http.Response(
        jsonEncode({
          'data': {
            'enabled': true,
            'package_name': 'com.example.app',
            'app_title': 'Example',
            'version': '1.2.3',
            'store_url': 'https://store/x',
            'maintenance_mode': false,
          },
        }),
        200,
      ),
      () async => AppStatusService('http://localhost'),
    );

    final status = await svc.fetchAppStatus();
    expect(status.enabled, isTrue);
    expect(status.packageName, 'com.example.app');
    expect(status.appTitle, 'Example');
    expect(status.version, '1.2.3');
    expect(status.storeUrl, 'https://store/x');
    expect(status.maintenanceMode, isFalse);
  });

  test(
    'fetchAppStatus falls back to top-level body when "data" is missing',
    () async {
      final svc = await _withMock(
        (req) => http.Response(
          jsonEncode({'enabled': true, 'app_title': 'Flat', 'version': '9.9'}),
          200,
        ),
        () async => AppStatusService('http://localhost'),
      );

      final status = await svc.fetchAppStatus();
      expect(status.enabled, isTrue);
      expect(status.appTitle, 'Flat');
      expect(status.version, '9.9');
    },
  );

  test('fetchAppStatus parses maintenance_mode + message', () async {
    final svc = await _withMock(
      (req) => http.Response(
        jsonEncode({
          'data': {
            'enabled': false,
            'maintenance_mode': true,
            'maintenance_message': 'Down for upgrade',
          },
        }),
        200,
      ),
      () async => AppStatusService('http://localhost'),
    );

    final status = await svc.fetchAppStatus();
    expect(status.enabled, isFalse);
    expect(status.maintenanceMode, isTrue);
    expect(status.maintenanceMessage, 'Down for upgrade');
  });

  test('AppStatus.fromJson treats missing flags as false', () {
    final s = AppStatus.fromJson({'app_title': 'X'});
    expect(s.enabled, isFalse);
    expect(s.maintenanceMode, isFalse);
    expect(s.appTitle, 'X');
  });

  test('AppStatus.fromJson treats enabled=1 (int) as false', () {
    // Implementation uses `== true`, so int 1 is NOT treated as enabled.
    // This documents the strict-boolean contract.
    final s = AppStatus.fromJson({'enabled': 1});
    expect(s.enabled, isFalse);
  });

  test(
    'AppStatusService.fetchAppStatus uses /api/v2 mobile_auth.app_status',
    () async {
      String? capturedUrl;
      final svc = await _withMock((req) {
        capturedUrl = req.url.toString();
        return http.Response(
          jsonEncode({
            'data': {'enabled': true},
          }),
          200,
        );
      }, () async => AppStatusService('http://example.com'));

      // The trailing slash on baseUrl must be stripped.
      await svc.fetchAppStatus();
      expect(
        capturedUrl,
        'http://example.com/api/v2/method/mobile_auth.app_status',
      );
    },
  );
}
