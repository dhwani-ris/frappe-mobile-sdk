import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/api/auth.dart';

void main() {
  group('FrappeClient construction', () {
    test('exposes baseUrl, rest, and the four sub-services', () {
      final c = FrappeClient('http://example.com');
      expect(c.baseUrl, 'http://example.com');
      expect(c.rest, isNotNull);
      expect(c.auth, isNotNull);
      expect(c.doctype, isNotNull);
      expect(c.document, isNotNull);
      expect(c.attachment, isNotNull);
    });

    test('trailing slash is stripped from baseUrl', () {
      expect(FrappeClient('http://example.com/').baseUrl, 'http://example.com');
    });

    test('doc(<doctype>) returns a QueryBuilder bound to that doctype', () {
      final qb = FrappeClient('http://x').doc('Customer');
      expect(qb, isNotNull);
    });
  });

  group('initialize delegates to auth.initialize', () {
    test('restores sid cookie from injected sessionStorage', () async {
      final storage = InMemorySessionStorage();
      await storage.saveSession('SID-1');

      Map<String, String>? observedHeaders;
      final c = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          observedHeaders = req.headers;
          return http.Response(jsonEncode({'ok': 1}), 200);
        }),
        sessionStorage: storage,
      );
      await c.initialize();
      await c.rest.get('/api/method/x');
      expect(observedHeaders!['Cookie'], contains('sid=SID-1'));
    });
  });

  group('call() routes via REST helper', () {
    test('POST default goes to /api/method/<name> with JSON body', () async {
      Uri? capturedUri;
      String? capturedBody;
      final c = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          capturedUri = req.url;
          capturedBody = req.body;
          return http.Response(jsonEncode({'message': 'ok'}), 200);
        }),
      );
      final r = await c.call(
        'frappe.client.get_value',
        args: {'doctype': 'X', 'name': 'a'},
      );
      expect(r, {'message': 'ok'});
      expect(capturedUri!.path, '/api/method/frappe.client.get_value');
      expect(jsonDecode(capturedBody!), {'doctype': 'X', 'name': 'a'});
    });

    test('GET puts args into query params', () async {
      Uri? capturedUri;
      final c = FrappeClient(
        'http://x',
        httpClient: MockClient((req) async {
          capturedUri = req.url;
          return http.Response(jsonEncode({'ok': 1}), 200);
        }),
      );
      await c.call('frappe.client.get', args: {'name': 'x'}, httpMethod: 'GET');
      expect(capturedUri!.queryParameters, {'name': 'x'});
    });
  });

  test('onTokenExpired callback is wired to RestHelper', () async {
    var refreshes = 0;
    var calls = 0;
    final c = FrappeClient(
      'http://x',
      httpClient: MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(jsonEncode({'exception': 'expired'}), 401);
        }
        return http.Response(jsonEncode({'ok': 1}), 200);
      }),
      onTokenExpired: () async {
        refreshes++;
        return true;
      },
    );
    c.rest.setBearerToken('expired');
    final r = await c.call('x');
    expect(r, {'ok': 1});
    expect(refreshes, 1);
  });

  test('requestHeaders mirrors the rest helper auth headers', () {
    final c = FrappeClient('http://x');
    c.rest.setBearerToken('jwt-abc');
    expect(c.requestHeaders['Authorization'], 'Bearer jwt-abc');
  });
}
