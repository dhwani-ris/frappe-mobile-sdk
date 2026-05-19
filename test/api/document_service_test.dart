import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/document_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

DocumentService _svc(http.Client client) =>
    DocumentService(RestHelper('http://x', client: client));

void main() {
  group('createDocument', () {
    test('POSTs /api/resource/<doctype> and unwraps {"data": ...}', () async {
      Uri? capturedUrl;
      final svc = _svc(
        MockClient((req) async {
          capturedUrl = req.url;
          return _json({
            'data': {'name': 'CUST-1', 'customer_name': 'Acme'},
          });
        }),
      );
      final r = await svc.createDocument('Customer', {'customer_name': 'Acme'});
      expect(r, {'name': 'CUST-1', 'customer_name': 'Acme'});
      expect(capturedUrl!.path, '/api/resource/Customer');
    });

    test('returns response as-is when no "data" envelope', () async {
      final svc = _svc(MockClient((_) async => _json({'name': 'X', 'a': 1})));
      final r = await svc.createDocument('Customer', {'a': 1});
      expect(r, {'name': 'X', 'a': 1});
    });

    test(
      'useFrappeClient=true POSTs /api/method/frappe.client.insert',
      () async {
        Uri? capturedUrl;
        Map<String, dynamic>? capturedBody;
        final svc = _svc(
          MockClient((req) async {
            capturedUrl = req.url;
            capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
            return _json({
              'message': {'name': 'CUST-1'},
            });
          }),
        );
        final r = await svc.createDocument('Customer', {
          'customer_name': 'Acme',
        }, useFrappeClient: true);
        expect(r, {'name': 'CUST-1'});
        expect(capturedUrl!.path, '/api/method/frappe.client.insert');
        final docStr = capturedBody!['doc'] as String;
        final doc = jsonDecode(docStr) as Map<String, dynamic>;
        expect(doc['doctype'], 'Customer');
        expect(doc['customer_name'], 'Acme');
      },
    );
  });

  group('updateDocument', () {
    test(
      'PUTs /api/resource/<doctype>/<name> and unwraps {"data": ...}',
      () async {
        Uri? capturedUrl;
        String? capturedMethod;
        final svc = _svc(
          MockClient((req) async {
            capturedUrl = req.url;
            capturedMethod = req.method;
            return _json({
              'data': {'name': 'CUST-1', 'customer_name': 'Updated'},
            });
          }),
        );
        final r = await svc.updateDocument('Customer', 'CUST-1', {
          'customer_name': 'Updated',
        });
        expect(r['customer_name'], 'Updated');
        expect(capturedMethod, 'PUT');
        expect(capturedUrl!.path, '/api/resource/Customer/CUST-1');
      },
    );

    test('returns response as-is when no "data" envelope', () async {
      final svc = _svc(MockClient((_) async => _json({'name': 'CUST-1'})));
      final r = await svc.updateDocument('Customer', 'CUST-1', {});
      expect(r, {'name': 'CUST-1'});
    });
  });

  group('deleteDocument', () {
    test('issues a DELETE to /api/resource/<doctype>/<name>', () async {
      Uri? capturedUrl;
      String? capturedMethod;
      final svc = _svc(
        MockClient((req) async {
          capturedUrl = req.url;
          capturedMethod = req.method;
          return _json({});
        }),
      );
      await svc.deleteDocument('Customer', 'CUST-1');
      expect(capturedMethod, 'DELETE');
      expect(capturedUrl!.path, '/api/resource/Customer/CUST-1');
    });
  });

  group('submitDocument / cancelDocument', () {
    test('submitDocument PUTs docstatus=1', () async {
      Map<String, dynamic>? body;
      final svc = _svc(
        MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({
            'data': {'docstatus': 1},
          });
        }),
      );
      await svc.submitDocument('Customer', 'CUST-1');
      expect(body, {'docstatus': 1});
    });

    test('cancelDocument PUTs docstatus=2', () async {
      Map<String, dynamic>? body;
      final svc = _svc(
        MockClient((req) async {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return _json({
            'data': {'docstatus': 2},
          });
        }),
      );
      await svc.cancelDocument('Customer', 'CUST-1');
      expect(body, {'docstatus': 2});
    });
  });
}
