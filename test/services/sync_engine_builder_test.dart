import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/closure_result.dart';
import 'package:frappe_mobile_sdk/src/models/dep_graph.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _emptyMeta(String name) =>
    DocTypeMeta(name: name, isTable: false, fields: const []);

DocField _f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
  });

  tearDown(() async => appDb.close());

  test('build() returns a non-null pack with the right object types', () async {
    final pack = await SyncEngineBuilder.build(
      database: appDb,
      client: FrappeClient('http://localhost'),
      metaResolver: (dt) async => _emptyMeta(dt),
      runPullFn: () async => const <String>{},
      applyServerDoc: (_, _) async {},
      runPullForDoctypes: (_) async {},
      concurrencyOverride: 2,
    );

    expect(pack.notifier, isNotNull);
    expect(pack.pullPool.maxConcurrent, 2);
    expect(pack.pushPool.maxConcurrent, 2);
    expect(pack.pushEngine, isNotNull);
    expect(pack.pullEngine, isNotNull);
    expect(pack.controller, isNotNull);
  });

  test(
    'pushPool and pullPool are independent ConcurrencyPool instances',
    () async {
      final pack = await SyncEngineBuilder.build(
        database: appDb,
        client: FrappeClient('http://localhost'),
        metaResolver: (dt) async => _emptyMeta(dt),
        runPullFn: () async => const <String>{},
        applyServerDoc: (_, _) async {},
        runPullForDoctypes: (_) async {},
        concurrencyOverride: 4,
      );

      expect(identical(pack.pushPool, pack.pullPool), isFalse);
    },
  );

  test('shared notifier is honored when supplied', () async {
    final shared = SyncStateNotifier();
    final pack = await SyncEngineBuilder.build(
      database: appDb,
      client: FrappeClient('http://localhost'),
      metaResolver: (dt) async => _emptyMeta(dt),
      runPullFn: () async => const <String>{},
      applyServerDoc: (_, _) async {},
      runPullForDoctypes: (_) async {},
      sharedNotifier: shared,
      concurrencyOverride: 2,
    );

    expect(identical(pack.notifier, shared), isTrue);
    await shared.close();
  });

  // The `listHttp` closure inside SyncEngineBuilder is the ONLY production
  // construction of `ListHttpPage`. Every fetcher/engine test injects its own
  // closure or builds `ListHttpPage` directly, so until now the real one was
  // unexercised: deleting its `scannedMaxModified:` / `scannedMaxName:`
  // arguments left the whole suite green while the incremental filtered-page
  // fix was inert in production. These drive the real closure over HTTP.
  group('listHttp routing (production closure)', () {
    const closure = ClosureResult(
      doctypes: ['Customer'],
      graph: {
        'Customer': DepGraph(
          doctype: 'Customer',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: {},
      warnings: [],
    );

    /// A meta with a `Table` field, so `metaHasChildTableFields` sends the
    /// closure down the `listFullDocsPage` branch.
    DocTypeMeta childBearing() => DocTypeMeta(
      name: 'Customer',
      fields: [
        _f('customer_name', 'Data'),
        _f('items', 'Table', options: 'Customer Item'),
      ],
    );

    Future<void> provisionCustomer(DocTypeMeta meta) async {
      final db = appDb.rawDatabase;
      for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
        await db.execute(s);
      }
      await db.insert('doctype_meta', {
        'doctype': 'Customer',
        'metaJson': '{}',
        'isMobileForm': 0,
        'table_name': 'docs__customer',
      });
    }

    Future<SyncEnginePack> packWith(DocTypeMeta meta, http.Client client) =>
        SyncEngineBuilder.build(
          database: appDb,
          client: FrappeClient('http://localhost', httpClient: client),
          metaResolver: (dt) async => meta,
          runPullFn: () async => const <String>{},
          applyServerDoc: (_, _) async {},
          runPullForDoctypes: (_) async {},
          concurrencyOverride: 1,
          pullPageSize: 2,
        );

    test('a fully permission-denied incremental page advances the watermark '
        'through the production closure', () async {
      final meta = childBearing();
      await provisionCustomer(meta);
      await appDb.doctypeMetaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:00","name":"C-1","complete":true}',
      );

      final listFilters = <String?>[];
      var listCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path.contains('get_list')) {
          listCalls++;
          listFilters.add(req.url.queryParameters['filters']);
          switch (listCalls) {
            case 1:
              // The denied window: two names, both dropped by the bulk
              // endpoint's per-doc permission gate below.
              return _json({
                'message': [
                  {'name': 'C-2', 'modified': '2026-01-02 00:00:00'},
                  {'name': 'C-3', 'modified': '2026-01-03 00:00:00'},
                ],
              });
            case 2:
              return _json({
                'message': [
                  {'name': 'C-9', 'modified': '2026-01-09 00:00:00'},
                ],
              });
            default:
              return _json({'message': <Map<String, dynamic>>[]});
          }
        }
        if (req.url.path.contains('get_docs_with_children')) {
          return _json({
            'message': listCalls == 1
                ? <Map<String, dynamic>>[]
                : [
                    {
                      'name': 'C-9',
                      'modified': '2026-01-09 00:00:00',
                      'customer_name': 'Iota',
                    },
                  ],
          });
        }
        return _json({});
      });

      final pack = await packWith(meta, client);
      await pack.pullEngine.run(closure);

      expect(
        listCalls,
        3,
        reason:
            'the denied window must be skipped, not treated as end-of-stream',
      );
      expect(
        jsonDecode(listFilters[1]!),
        [
          ['modified', '>=', '2026-01-03 00:00:00'],
        ],
        reason:
            'THE proof that the fix is reachable in production. The second '
            'request must resume from the DENIED window\'s scanned max. Delete '
            'the `scannedMaxModified:`/`scannedMaxName:` arguments from '
            '`ListHttpPage(...)` in sync_engine_builder.dart and this is still '
            '`2026-01-01 00:00:00`: the watermark stays pinned, the pull ends '
            'at request 1, and C-9 is unreachable forever — while every other '
            'test in the suite still passes, because they all build '
            '`ListHttpPage` themselves.',
      );
      final rows = await appDb.rawDatabase.query('docs__customer');
      expect(
        rows.map((r) => r['server_name']),
        contains('C-9'),
        reason: 'the row behind the denied window must still be pulled',
      );
      final cursor =
          jsonDecode((await appDb.doctypeMetaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(cursor['modified'], '2026-01-09 00:00:00');
    });

    test('a malformed bulk response must NOT advance the watermark past '
        'readable rows', () async {
      // THE data-loss guard, end to end. An unparseable 2xx on the bulk
      // endpoint used to surface as `docs: []` with a non-zero `namesScanned`
      // — byte-identical to a legitimately all-denied window — so the
      // incremental skip would advance `modified` past rows that are READABLE
      // and were never fetched, and checkpoint it. Permanent silent loss,
      // recoverable only by clearing the cursor.
      //
      // `bulkGetWithChildren` now throws on a non-list `message`, so the page
      // fails, `PullEngine`'s mid-pull catch declines to persist, and the
      // window is retried next cycle. The watermark must not move one tick.
      final meta = childBearing();
      await provisionCustomer(meta);
      await appDb.doctypeMetaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:00","name":"C-1","complete":true}',
      );

      final client = MockClient((req) async {
        if (req.url.path.contains('get_list')) {
          // Five readable names, the newest at 2026-01-04.
          return _json({
            'message': [
              for (var i = 1; i <= 5; i++)
                {'name': 'C-$i', 'modified': '2026-01-0$i 00:00:00'},
            ],
          });
        }
        if (req.url.path.contains('get_docs_with_children')) {
          // Truncated body on the SDK's largest payload — a 200 that cannot
          // be parsed. RestHelper hands back the raw String.
          return http.Response('{"message": [{"name": "C-1"', 200);
        }
        return _json({});
      });

      final pack = await packWith(meta, client);
      await pack.pullEngine.run(closure);

      final cursor =
          jsonDecode((await appDb.doctypeMetaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(
        cursor['modified'],
        '2026-01-01 00:00:00',
        reason:
            'the watermark MUST stay put. Reverting the throw in '
            '`bulkGetWithChildren` makes this read 2026-01-05 — the scanned '
            'window max — putting all five readable rows behind the watermark '
            'where neither pull path will ever return them again. That is the '
            'exact permanent silent loss this guards.',
      );
      expect(
        cursor['complete'],
        isTrue,
        reason: 'a failed page must not flip the doctype out of incremental',
      );
      expect(
        await appDb.rawDatabase.query('docs__customer'),
        isEmpty,
        reason: 'nothing was applied, so nothing may be claimed as pulled',
      );
    });

    test('the name query asks the server for modified', () async {
      // Without `modified` in the projection the scanned-window watermark
      // cannot be computed at all, and the closure degrades to stop-and-retry.
      final meta = childBearing();
      await provisionCustomer(meta);
      String? fields;
      final client = MockClient((req) async {
        if (req.url.path.contains('get_list')) {
          fields ??= req.url.queryParameters['fields'];
          return _json({'message': <Map<String, dynamic>>[]});
        }
        return _json({});
      });

      final pack = await packWith(meta, client);
      await pack.pullEngine.run(closure);

      expect(fields, isNotNull);
      expect(jsonDecode(fields!), containsAll(['name', 'modified']));
    });

    test('a doctype with no Table field takes the flat path and pages by rows '
        'returned', () async {
      final meta = DocTypeMeta(
        name: 'Customer',
        fields: [_f('customer_name', 'Data')],
      );
      await provisionCustomer(meta);
      final starts = <String?>[];
      var listCalls = 0;
      var bulkCalls = 0;
      final client = MockClient((req) async {
        if (req.url.path.contains('get_docs_with_children')) {
          bulkCalls++;
          return _json({'message': <Map<String, dynamic>>[]});
        }
        if (req.url.path.contains('get_list')) {
          listCalls++;
          starts.add(req.url.queryParameters['limit_start']);
          if (listCalls == 1) {
            return _json({
              'message': [
                {
                  'name': 'C-1',
                  'modified': '2026-01-01 00:00:00',
                  'customer_name': 'Alpha',
                },
                {
                  'name': 'C-2',
                  'modified': '2026-01-02 00:00:00',
                  'customer_name': 'Beta',
                },
              ],
            });
          }
          return _json({'message': <Map<String, dynamic>>[]});
        }
        return _json({});
      });

      final pack = await packWith(meta, client);
      await pack.pullEngine.run(closure);

      expect(
        bulkCalls,
        0,
        reason:
            'a doctype with no child-table field must never reach the bulk '
            'endpoint — the flat get_list returns every row it lists',
      );
      expect(starts, ['0', '2'], reason: 'the flat path pages by rows.length');
    });
  });
}
