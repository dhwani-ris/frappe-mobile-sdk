import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

DoctypeService _svc(http.Client client) =>
    DoctypeService(RestHelper('http://x', client: client));

/// A Frappe `frappe.throw(..., ValidationError)` reply: HTTP 417 with the
/// message carried in `_server_messages`. This is what a server still on
/// `MAX_BATCH = 200` returns when the client sends a bigger batch.
http.Response _batchTooLarge(int limit) => _json({
      'exc_type': 'ValidationError',
      '_server_messages': jsonEncode([
        jsonEncode({
          'message': 'Batch size 1000 exceeds limit of $limit',
          'title': 'Message',
        }),
      ]),
    }, 417);

List<Map<String, String>> _names(int n) =>
    [for (var i = 0; i < n; i++) {'name': 'DOC-$i'}];

void main() {
  group('listFullDocs batching', () {
    test('a 1000-row page is one bulk call, not five', () async {
      // The pull engine pages at 1000. Chunking below that turns every page
      // into extra round-trips — six to move 1000 rows, at ~1.1s each
      // against prod.
      var bulkCalls = 0;
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            return _json({'message': _names(1000)});
          }
          if (req.url.path.contains('get_docs_with_children')) {
            bulkCalls++;
            final sent =
                jsonDecode(req.body) as Map<String, dynamic>;
            expect((sent['names'] as List), hasLength(1000));
            return _json({'message': _names(1000)});
          }
          return _json({});
        }),
      );

      final out = await svc.listFullDocs('Customer');

      expect(out, hasLength(1000));
      expect(bulkCalls, 1);
    });

    test('falls back to smaller batches against a server on the old cap',
        () async {
      // mobile_control ships the matching cap, but a device can reach a
      // backend that has not been deployed yet. Refusing the whole page
      // would strand the doctype; re-chunking costs a round-trip and
      // completes.
      var attemptedSizes = <int>[];
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            return _json({'message': _names(1000)});
          }
          if (req.url.path.contains('get_docs_with_children')) {
            final sent = jsonDecode(req.body) as Map<String, dynamic>;
            final n = (sent['names'] as List).length;
            attemptedSizes.add(n);
            if (n > 200) return _batchTooLarge(200);
            return _json({'message': _names(n)});
          }
          return _json({});
        }),
      );

      final out = await svc.listFullDocs('Customer');

      expect(out, hasLength(1000));
      expect(attemptedSizes.first, 1000,
          reason: 'should try the full page before backing off');
      expect(attemptedSizes.where((n) => n <= 200), hasLength(5),
          reason: 'five 200-name chunks complete the page');
    });

    test('a discovered cap is remembered for the rest of the session',
        () async {
      // The pull walks ~79 pages of a heavy doctype. Re-discovering an old
      // server's cap on every page would mean 79 rejected requests, each
      // carrying a full 1000-name payload.
      var oversized = 0;
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            return _json({'message': _names(400)});
          }
          final sent = jsonDecode(req.body) as Map<String, dynamic>;
          final n = (sent['names'] as List).length;
          if (n > 200) {
            oversized++;
            return _batchTooLarge(200);
          }
          return _json({'message': _names(n)});
        }),
      );

      await svc.listFullDocs('Customer');
      await svc.listFullDocs('Customer');
      await svc.listFullDocs('Customer');

      expect(oversized, 1,
          reason: 'the cap is learned once, not once per page');
    });

    test('the batch-size retry does not loop forever', () async {
      // A server that rejects every size must surface the error rather
      // than halve down to one name and hammer the backend 1000 times.
      var calls = 0;
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            return _json({'message': _names(1000)});
          }
          calls++;
          return _batchTooLarge(0);
        }),
      );

      await expectLater(
        svc.listFullDocs('Customer'),
        throwsA(isA<Exception>()),
      );
      expect(calls, lessThan(20));
    });

    test('a non-batch-size error is not retried as one', () async {
      var calls = 0;
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            return _json({'message': _names(10)});
          }
          calls++;
          return _json({'exc_type': 'PermissionError'}, 403);
        }),
      );

      await expectLater(
        svc.listFullDocs('Customer'),
        throwsA(isA<Exception>()),
      );
      expect(calls, 1);
    });
  });
}
