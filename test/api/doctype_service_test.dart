import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
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

    test('an all-denied batch is still a legitimate empty result', () async {
      // `{"message": []}` is how the endpoint reports "every requested name
      // was denied or deleted". This MUST stay non-throwing — it is the input
      // the permission-filtered-page logic is built on.
      final svc = _svc(
        MockClient((_) async => _json({'message': <Map<String, dynamic>>[]})),
      );
      expect(await svc.bulkGetWithChildren('Customer', ['CUST-1']), isEmpty);
    });

    test('a 2xx body that is not a list THROWS rather than reporting an '
        'empty batch', () async {
      // Data-loss guard. An empty batch means "every name denied", which the
      // incremental pull uses as licence to advance the watermark past the
      // scanned window. A malformed 2xx that returned `[]` here would move the
      // watermark past READABLE, never-fetched rows — permanent silent loss.
      // Failing the page leaves the cursor untouched so the window is retried.
      final svc = _svc(MockClient((_) async => _json({'message': 'oops'})));
      await expectLater(
        svc.bulkGetWithChildren('Customer', ['CUST-1']),
        throwsA(
          isA<ApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNot(404),
          ),
        ),
        reason:
            'must not be 404 — the caller degrades 404 to per-name GETs, which '
            'would mask a transient upstream failure as an N+1 success',
      );
    });

    test('an unparseable 2xx body THROWS (RestHelper hands back a raw '
        'String)', () async {
      // `RestHelper._handleResponse` returns the raw body for any 2xx whose
      // jsonDecode fails, so a truncated response on the SDK's largest payload
      // lands in the `message is! List` branch as a String, not a Map.
      final svc = _svc(
        MockClient(
          (_) async => http.Response('{"message": [{"name": "CUST-1"', 200),
        ),
      );
      await expectLater(
        svc.bulkGetWithChildren('Customer', ['CUST-1']),
        throwsA(isA<ApiException>()),
      );
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

  group('listFullDocsPage', () {
    /// Serves [names] from `get_list` and [docs] from the bulk endpoint.
    /// [modifiedByName] attaches a `modified` to the listed name row for that
    /// name, mirroring the widened `fields: ['name', 'modified']` projection;
    /// a name absent from the map lists without one.
    DoctypeService svcWith({
      required List<String> names,
      required List<Map<String, dynamic>> docs,
      Map<String, String>? modifiedByName,
    }) => _svc(
      MockClient((req) async {
        if (req.url.path.contains('get_list')) {
          return _json({
            'message': [
              for (final n in names)
                {
                  'name': n,
                  if (modifiedByName?[n] != null)
                    'modified': modifiedByName![n],
                },
            ],
          });
        }
        if (req.url.path.contains('get_docs_with_children')) {
          return _json({'message': docs});
        }
        return _json({});
      }),
    );

    test('emits docs in the requested names order, not arrival order', () async {
      // `bulkGetWithChildren` is a `names in (...)` fetch and nothing in the
      // request obliges the server to honour the caller's `order_by`. The pull
      // watermark is derived from the page's rows, so returning them in
      // arrival order silently violated the `modified asc, name asc` contract.
      final svc = svcWith(
        names: ['CUST-1', 'CUST-2', 'CUST-3'],
        docs: const [
          {'name': 'CUST-3', 'modified': '2026-01-03 00:00:00'},
          {'name': 'CUST-1', 'modified': '2026-01-01 00:00:00'},
          {'name': 'CUST-2', 'modified': '2026-01-02 00:00:00'},
        ],
      );
      final page = await svc.listFullDocsPage(
        'Customer',
        orderBy: 'modified asc',
      );
      expect(page.docs.map((d) => d['name']).toList(), [
        'CUST-1',
        'CUST-2',
        'CUST-3',
      ]);
      expect(page.namesScanned, 3);
    });

    test('reports namesScanned when the permission gate drops names', () async {
      // bulkGetWithChildren applies doc.check_permission("read"), which brings
      // in document-level has_permission hooks that get_list never evaluates —
      // so fewer docs than names is normal, not an error.
      final svc = svcWith(
        names: ['CUST-1', 'CUST-2', 'CUST-3'],
        docs: const [
          {'name': 'CUST-2', 'modified': '2026-01-02 00:00:00'},
        ],
      );
      final page = await svc.listFullDocsPage('Customer');
      expect(page.docs, hasLength(1));
      expect(
        page.namesScanned,
        3,
        reason:
            'the caller must be able to advance its offset by names '
            'consumed, not by docs returned',
      );
    });

    test(
      'a fully-filtered page reports zero docs but non-zero namesScanned',
      () async {
        // This is the H3 case: indistinguishable from end-of-stream without
        // namesScanned, which made the pull mark the doctype fully drained and
        // never fetch any later page.
        final svc = svcWith(names: ['CUST-1', 'CUST-2'], docs: const []);
        final page = await svc.listFullDocsPage('Customer');
        expect(page.docs, isEmpty);
        expect(page.namesScanned, 2);
      },
    );

    test('a genuinely exhausted page reports namesScanned == 0', () async {
      final svc = svcWith(names: const [], docs: const []);
      final page = await svc.listFullDocsPage('Customer');
      expect(page.docs, isEmpty);
      expect(page.namesScanned, 0);
      expect(
        page.scannedMaxModified,
        isNull,
        reason:
            'the `nameList.isEmpty` early return scanned no window, so it has '
            'no watermark to offer',
      );
      expect(page.scannedMaxName, isNull);
    });

    test(
      "reports the scanned window's max even when every doc is dropped",
      () async {
        final svc = svcWith(
          names: ['CUST-1', 'CUST-2', 'CUST-3'],
          docs: const [],
          modifiedByName: const {
            'CUST-1': '2026-01-01 00:00:00',
            'CUST-2': '2026-01-02 00:00:00',
            'CUST-3': '2026-01-03 00:00:00',
          },
        );
        final page = await svc.listFullDocsPage('Customer');
        expect(page.namesScanned, 3);
        expect(
          page.scannedMaxModified,
          '2026-01-03 00:00:00',
          reason:
              'the H3 case: the incremental pull pins `limit_start` at 0, so '
              'it has no offset to step an all-denied block over — the '
              'scanned window watermark is the only thing that can move the '
              'cursor past it',
        );
        expect(page.scannedMaxName, 'CUST-3');
      },
    );

    test('the watermark is the window MAX, not the last listed row', () async {
      // Served deliberately out of `modified` order: the LAST row listed
      // (CUST-2) carries a LOWER `modified` than CUST-3 before it.
      final svc = svcWith(
        names: ['CUST-1', 'CUST-3', 'CUST-2'],
        docs: const [],
        modifiedByName: const {
          'CUST-1': '2026-01-01 00:00:00',
          'CUST-3': '2026-01-03 00:00:00',
          'CUST-2': '2026-01-02 00:00:00',
        },
      );
      final page = await svc.listFullDocsPage('Customer');
      expect(
        page.scannedMaxModified,
        '2026-01-03 00:00:00',
        reason:
            'taking the max rather than the last row is what keeps a '
            'watermark from ever moving BACKWARDS if the server stops '
            'honouring `order_by`',
      );
      expect(page.scannedMaxName, 'CUST-3');
    });

    test('null watermark when the listed rows carry no modified', () async {
      final svc = svcWith(names: ['CUST-1', 'CUST-2'], docs: const []);
      final page = await svc.listFullDocsPage('Customer');
      expect(page.namesScanned, 2);
      expect(
        page.scannedMaxModified,
        isNull,
        reason:
            'null means the caller must not advance: the code degrades to '
            "today's stop-and-retry rather than inventing a watermark",
      );
      expect(page.scannedMaxName, isNull);
    });

    test('asks the name query for modified', () async {
      Uri? captured;
      final svc = _svc(
        MockClient((req) async {
          if (req.url.path.contains('get_list')) {
            captured = req.url;
            return _json({'message': const []});
          }
          return _json({});
        }),
      );
      await svc.listFullDocsPage('Customer');
      expect(
        jsonDecode(captured!.queryParameters['fields']!),
        containsAll(<String>['name', 'modified']),
        reason:
            'projecting `modified` on the name query is what makes the '
            'scanned window watermark obtainable at all',
      );
    });

    test(
      'a doc the server returns but that was never requested is dropped',
      () async {
        final svc = svcWith(
          names: ['CUST-1'],
          docs: const [
            {'name': 'CUST-1'},
            {'name': 'CUST-99'},
          ],
        );
        final page = await svc.listFullDocsPage('Customer');
        expect(page.docs.map((d) => d['name']).toList(), ['CUST-1']);
      },
    );

    test(
      'listFullDocs delegates and preserves its List return contract',
      () async {
        final svc = svcWith(
          names: ['CUST-2', 'CUST-1'],
          docs: const [
            {'name': 'CUST-1'},
            {'name': 'CUST-2'},
          ],
        );
        final out = await svc.listFullDocs('Customer');
        expect(out, isA<List<Map<String, dynamic>>>());
        expect(
          out.map((d) => d['name']).toList(),
          ['CUST-2', 'CUST-1'],
          reason: 'names order, which here is deliberately not sorted order',
        );
      },
    );
  });
}
