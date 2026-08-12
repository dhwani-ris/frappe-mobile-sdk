import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/api/doctype_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_details.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

DoctypeService _svc(http.Client client) =>
    DoctypeService(RestHelper('http://x', client: client));

void main() {
  test('returns null for empty input without a network call', () async {
    var hit = false;
    final svc = _svc(
      MockClient((_) async {
        hit = true;
        return _json({'message': {}});
      }),
    );
    final r = await svc.getSyncDetails(const []);
    expect(r, isNull);
    expect(hit, isFalse, reason: 'empty input must not call the network');
  });

  test('posts the right body and parses a message-wrapped manifest', () async {
    String? capturedPath;
    Map<String, dynamic>? capturedBody;
    final svc = _svc(
      MockClient((req) async {
        capturedPath = req.url.path;
        capturedBody = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({
          'message': {
            'doctypes': [
              {
                'doctype': 'Patient',
                'changed': true,
                'count': 2,
                'meta_bumped': false,
              },
            ],
            'delete_signals': 0,
          },
        });
      }),
    );
    final r = await svc.getSyncDetails([
      {'doctype': 'Patient', 'since': '2026-01-01 00:00:00.000000'},
    ]);
    expect(capturedPath, '/api/method/mobile_sync.sync_details');
    expect((capturedBody!['doctypes'] as List).first['doctype'], 'Patient');
    expect(r, isA<SyncDetailsResponse>());
    expect(r!.entries['Patient']!.changed, isTrue);
    expect(r.entries['Patient']!.count, 2);
  });

  test('returns null on transport error (graceful fallback)', () async {
    final svc = _svc(MockClient((_) async => _json({'error': 'boom'}, 500)));
    final r = await svc.getSyncDetails([
      {'doctype': 'Patient', 'since': '2026-01-01 00:00:00.000000'},
    ]);
    expect(r, isNull);
  });

  List<Map<String, String>> makeEntries(int n) => [
    for (var i = 0; i < n; i++)
      {'doctype': 'DT$i', 'since': '2026-01-01 00:00:00.000000'},
  ];

  http.Response manifestFor(http.Request req) {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final dts = (body['doctypes'] as List).cast<Map<String, dynamic>>();
    return _json({
      'message': {
        'doctypes': [
          for (final d in dts)
            {
              'doctype': d['doctype'],
              'changed': false,
              'count': 0,
              'meta_bumped': false,
            },
        ],
        'delete_signals': 0,
      },
    });
  }

  test(
    'at the 100-doctype cap: exactly ONE call (legacy behaviour unchanged)',
    () async {
      final sizes = <int>[];
      final svc = _svc(
        MockClient((req) async {
          sizes.add(((jsonDecode(req.body)['doctypes']) as List).length);
          return manifestFor(req);
        }),
      );
      final r = await svc.getSyncDetails(makeEntries(100));
      expect(sizes, [100], reason: 'a request at the cap must not be chunked');
      expect(r!.entries.length, 100);
    },
  );

  test('over the cap: transparently chunks into <=100 and merges', () async {
    final sizes = <int>[];
    final svc = _svc(
      MockClient((req) async {
        sizes.add(((jsonDecode(req.body)['doctypes']) as List).length);
        return manifestFor(req);
      }),
    );
    final r = await svc.getSyncDetails(makeEntries(250));
    // 250 -> 100 + 100 + 50, three calls, none exceeding the server cap.
    expect(sizes, [100, 100, 50]);
    expect(
      sizes.every((s) => s <= 100),
      isTrue,
      reason: 'no chunk may exceed the server MAX_DOCTYPES (417 guard)',
    );
    expect(r, isA<SyncDetailsResponse>());
    expect(r!.entries.length, 250, reason: 'all chunks merged');
    expect(r.entries['DT0']!.changed, isFalse);
    expect(r.entries['DT249']!.changed, isFalse);
  });

  test(
    'over the cap: a single failed chunk => null (all-or-nothing full pull)',
    () async {
      var call = 0;
      final svc = _svc(
        MockClient((req) async {
          call++;
          // Fail the 2nd chunk only.
          if (call == 2) return _json({'error': 'boom'}, 500);
          return manifestFor(req);
        }),
      );
      final r = await svc.getSyncDetails(makeEntries(150));
      expect(
        r,
        isNull,
        reason: 'any chunk failure must fall back to full pull',
      );
    },
  );
}
