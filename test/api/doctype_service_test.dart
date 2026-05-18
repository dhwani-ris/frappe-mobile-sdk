import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

DoctypeService _svc(http.Client client) =>
    DoctypeService(RestHelper('http://x', client: client));

void main() {
  group('getDocTypeMeta', () {
    test('returns response when it contains "docs" key', () async {
      final svc = _svc(
        MockClient(
          (_) async => _json({
            'docs': [
              {'name': 'Customer'},
            ],
          }),
        ),
      );
      final r = await svc.getDocTypeMeta('Customer');
      expect(r['docs'], isA<List>());
    });

    test('returns raw response when no docs envelope', () async {
      final svc = _svc(
        MockClient((_) async => _json({'message': 'no docs key here'})),
      );
      final r = await svc.getDocTypeMeta('Customer');
      expect(r['message'], 'no docs key here');
    });
  });

  group('getDocTypeWatermark', () {
    test('extracts the modified timestamp', () async {
      final svc = _svc(
        MockClient(
          (_) async => _json({
            'message': {'modified': '2026-05-18 09:00:00'},
          }),
        ),
      );
      final r = await svc.getDocTypeWatermark('Customer');
      expect(r, '2026-05-18 09:00:00');
    });

    test('returns null when message is not a map', () async {
      final svc = _svc(MockClient((_) async => _json({'message': null})));
      expect(await svc.getDocTypeWatermark('Customer'), isNull);
    });

    test('returns null on server error (swallows exceptions)', () async {
      final svc = _svc(MockClient((_) async => _json({'oops': 'x'}, 500)));
      expect(await svc.getDocTypeWatermark('Customer'), isNull);
    });
  });

  group('list', () {
    test('returns the message list when shape matches', () async {
      final svc = _svc(
        MockClient(
          (_) async => _json({
            'message': [
              {'name': 'CUST-1'},
              {'name': 'CUST-2'},
            ],
          }),
        ),
      );
      final out = await svc.list('Customer');
      expect(out, hasLength(2));
    });

    test('returns empty list when message is not a list', () async {
      final svc = _svc(MockClient((_) async => _json({'message': 'oops'})));
      expect(await svc.list('Customer'), isEmpty);
    });

    test('returns empty list when response has no message key', () async {
      final svc = _svc(MockClient((_) async => _json({'unrelated': 'shape'})));
      expect(await svc.list('Customer'), isEmpty);
    });

    test(
      'serializes fields / filters / or_filters / order_by into query',
      () async {
        Uri? captured;
        final svc = _svc(
          MockClient((req) async {
            captured = req.url;
            return _json({'message': []});
          }),
        );
        await svc.list(
          'Customer',
          fields: ['name', 'customer_name'],
          filters: [
            ['name', '=', 'X'],
          ],
          orFilters: [
            ['name', 'like', '%X%'],
          ],
          orderBy: 'modified desc',
        );
        final qp = captured!.queryParameters;
        expect(qp['doctype'], 'Customer');
        expect(qp['fields'], '["name","customer_name"]');
        expect(qp['filters'], '[["name","=","X"]]');
        expect(qp['or_filters'], '[["name","like","%X%"]]');
        expect(qp['order_by'], 'modified desc');
        expect(qp['limit_start'], '0');
        expect(qp['limit_page_length'], '20');
      },
    );

    test('omits or_filters from query when empty', () async {
      Uri? captured;
      final svc = _svc(
        MockClient((req) async {
          captured = req.url;
          return _json({'message': []});
        }),
      );
      await svc.list('Customer', orFilters: const []);
      expect(captured!.queryParameters.containsKey('or_filters'), isFalse);
    });
  });

  group('count', () {
    test('returns int message verbatim', () async {
      final svc = _svc(MockClient((_) async => _json({'message': 42})));
      expect(await svc.count('Customer'), 42);
    });

    test('coerces num message to int', () async {
      final svc = _svc(MockClient((_) async => _json({'message': 12.0})));
      expect(await svc.count('Customer'), 12);
    });

    test('parses string-numeric message', () async {
      final svc = _svc(MockClient((_) async => _json({'message': '5'})));
      expect(await svc.count('Customer'), 5);
    });

    test('returns 0 on malformed message', () async {
      final svc = _svc(MockClient((_) async => _json({'message': 'bogus'})));
      expect(await svc.count('Customer'), 0);
    });
  });

  group('getByName', () {
    test('unwraps {"data": {...}} envelope', () async {
      final svc = _svc(
        MockClient(
          (_) async => _json({
            'data': {'name': 'CUST-1', 'customer_name': 'Acme'},
          }),
        ),
      );
      final r = await svc.getByName('Customer', 'CUST-1');
      expect(r, {'name': 'CUST-1', 'customer_name': 'Acme'});
    });
  });

  group('bulkGetWithChildren', () {
    test('empty names list returns empty without hitting server', () async {
      var calls = 0;
      final svc = _svc(
        MockClient((_) async {
          calls++;
          return _json({});
        }),
      );
      expect(await svc.bulkGetWithChildren('Customer', const []), isEmpty);
      expect(calls, 0);
    });

    test('parses {"message": [...]} into list of maps', () async {
      final svc = _svc(
        MockClient(
          (_) async => _json({
            'message': [
              {'name': 'CUST-1', 'customer_name': 'Acme'},
              {'name': 'CUST-2', 'customer_name': 'Beta'},
            ],
          }),
        ),
      );
      final out = await svc.bulkGetWithChildren('Customer', [
        'CUST-1',
        'CUST-2',
      ]);
      expect(out, hasLength(2));
      expect(out.first['name'], 'CUST-1');
    });

    test('returns empty list when message is not a list', () async {
      final svc = _svc(MockClient((_) async => _json({'message': 'oops'})));
      expect(await svc.bulkGetWithChildren('Customer', ['CUST-1']), isEmpty);
    });
  });

  group('listFullDocs', () {
    test('happy path: fetches names then bulk-loads docs', () async {
      var hits = <String>[];
      final svc = _svc(
        MockClient((req) async {
          hits.add(req.url.path);
          if (req.url.path.contains('get_list')) {
            return _json({
              'message': [
                {'name': 'CUST-1'},
                {'name': 'CUST-2'},
              ],
            });
          }
          if (req.url.path.contains('get_docs_with_children')) {
            return _json({
              'message': [
                {'name': 'CUST-1', 'customer_name': 'Acme'},
                {'name': 'CUST-2', 'customer_name': 'Beta'},
              ],
            });
          }
          return _json({});
        }),
      );
      final out = await svc.listFullDocs('Customer');
      expect(out, hasLength(2));
      expect(hits.any((p) => p.contains('get_list')), isTrue);
      expect(hits.any((p) => p.contains('get_docs_with_children')), isTrue);
    });

    test('empty name page short-circuits without bulk call', () async {
      var bulkCalls = 0;
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            return _json({'message': const []});
          }
          if (req.url.path.contains('get_docs_with_children')) {
            bulkCalls++;
          }
          return _json({});
        }),
      );
      final out = await svc.listFullDocs('Customer');
      expect(out, isEmpty);
      expect(bulkCalls, 0);
    });

    test(
      '404 on bulk endpoint falls back to per-name /api/resource fetches',
      () async {
        final svc = _svc(
          MockClient((req) async {
            if (req.url.path.contains('get_list')) {
              return _json({
                'message': [
                  {'name': 'CUST-1'},
                ],
              });
            }
            if (req.url.path.contains('get_docs_with_children')) {
              return _json({'exception': 'not_installed'}, 404);
            }
            if (req.url.path.contains('/api/resource/Customer/CUST-1')) {
              return _json({
                'data': {'name': 'CUST-1', 'customer_name': 'FromFallback'},
              });
            }
            return _json({});
          }),
        );
        final out = await svc.listFullDocs('Customer');
        expect(out, hasLength(1));
        expect(out.single['customer_name'], 'FromFallback');
      },
    );

    test('5xx on bulk endpoint propagates (no fallback)', () async {
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            return _json({
              'message': [
                {'name': 'CUST-1'},
              ],
            });
          }
          if (req.url.path.contains('get_docs_with_children')) {
            return _json({'exception': 'server boom'}, 500);
          }
          return _json({});
        }),
      );
      await expectLater(svc.listFullDocs('Customer'), throwsA(isException));
    });
  });
}
