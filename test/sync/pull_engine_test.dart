import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_page_fetcher.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/concurrency/write_queue.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/closure_result.dart';
import 'package:frappe_mobile_sdk/src/models/dep_graph.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// In-memory `frappe.client.get_list` stand-in that honours the two-phase
/// KEYSET contract (AND-only `filters` + `order_by` + `limit_page_length`),
/// so a full multi-page PullEngine drive exercises the real keyset paging.
/// Rows carry string `modified` + `name` (both lexicographically ordered
/// here). Records every params map and can be told to throw on the Nth call
/// to simulate a mid-pull network failure.
class FakeListServer {
  final List<Map<String, dynamic>> rows;
  int throwOnCall; // 1-based call index to throw on; 0 = never
  int callCount = 0;
  final List<Map<String, Object?>> requests = [];

  FakeListServer(this.rows, {this.throwOnCall = 0});

  void reset({int throwOnCall = 0}) {
    callCount = 0;
    this.throwOnCall = throwOnCall;
    requests.clear();
  }

  Future<List<Map<String, dynamic>>> call(
    String doctype,
    Map<String, Object?> params,
  ) async {
    callCount++;
    requests.add(Map.of(params));
    if (throwOnCall != 0 && callCount == throwOnCall) {
      throw Exception('injected network failure on call $callCount');
    }
    final filters =
        (params['filters'] as List?)?.cast<List>() ?? const <List>[];
    final order = params['order_by'] as String? ?? 'modified asc, name asc';
    final limit = params['limit_page_length'] as int? ?? rows.length;

    Iterable<Map<String, dynamic>> out = rows;
    for (final fr in filters) {
      final field = fr[0] as String;
      final op = fr[1] as String;
      final val = fr[2] as String;
      out = out.where((r) {
        final c = (r[field] as String).compareTo(val);
        switch (op) {
          case '=':
            return c == 0;
          case '>':
            return c > 0;
          case '>=':
            return c >= 0;
          case '<':
            return c < 0;
          default:
            return true;
        }
      });
    }
    final list = out.toList();
    list.sort((a, b) {
      if (order.startsWith('name')) {
        return (a['name'] as String).compareTo(b['name'] as String);
      }
      final c = (a['modified'] as String).compareTo(b['modified'] as String);
      return c != 0 ? c : (a['name'] as String).compareTo(b['name'] as String);
    });
    return list.take(limit).toList();
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DoctypeMetaDao metaDao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL,
        groupName TEXT,
        sortOrder INTEGER
      )
    ''');
    for (final s in doctypeMetaExtensionsDDL()) {
      await db.execute(s);
    }
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }

    final meta = DocTypeMeta(
      name: 'Customer',
      fields: [f('customer_name', 'Data')],
    );
    for (final s in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });

    metaDao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  test('pulls one doctype, one page, advances cursor on success', () async {
    var calls = 0;
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        calls++;
        return calls == 1
            ? [
                {
                  'name': 'C-1',
                  'modified': '2026-01-01 00:00:00',
                  'customer_name': 'Acme',
                },
              ]
            : const <Map<String, dynamic>>[];
      },
    );
    final closure = const ClosureResult(
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
    final notifier = SyncStateNotifier();
    final engine = PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: fetcher,
      pageSize: 500,
      notifier: notifier,
      metaResolver: (dt) async =>
          DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
    );
    await engine.run(closure);

    final rows = await db.query('docs__customer');
    expect(rows.length, 1);
    final cursor = await metaDao.getLastOkCursor('Customer');
    expect(cursor, isNot(isNull));
    // SIG-9: persisted cursor JSON must include `complete: true` once the
    // doctype drains, so SyncService._pullOneInternal can read it without
    // falling back into a re-fetch loop.
    final parsed = jsonDecode(cursor!) as Map<String, dynamic>;
    expect(parsed['complete'], isTrue);
    expect(notifier.value.perDoctype.containsKey('Customer'), isTrue);
    expect(notifier.value.perDoctype['Customer']!.pulledCount, 1);
    expect(notifier.value.perDoctype['Customer']!.completedAt, isNotNull);
  });

  test('defers pull when outbox has active push for that doctype', () async {
    final outboxDao = OutboxDao(db);
    await outboxDao.insertPending(
      doctype: 'Customer',
      mobileUuid: 'u',
      operation: OutboxOperation.insert,
    );
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        fail('fetcher should not be called for a deferred doctype');
      },
    );
    final closure = const ClosureResult(
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
    final notifier = SyncStateNotifier();
    final engine = PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: outboxDao,
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: fetcher,
      pageSize: 500,
      notifier: notifier,
      metaResolver: (dt) async => DocTypeMeta(name: dt, fields: const []),
    );
    final deferred = await engine.run(closure);
    expect(notifier.value.perDoctype['Customer']!.deferred, isTrue);
    // SIG-2: caller needs to know which doctypes were deferred so it can
    // re-pull them after the push engine drains.
    expect(deferred, contains('Customer'));
  });

  test('PullEngine.run returns empty set when nothing was deferred', () async {
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async => const [],
    );
    final closure = const ClosureResult(
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
    final engine = PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: fetcher,
      pageSize: 500,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async => DocTypeMeta(name: dt, fields: const []),
    );
    final deferred = await engine.run(closure);
    expect(deferred, isEmpty);
  });

  test('skips child doctypes (they ride with parent)', () async {
    final closure = const ClosureResult(
      doctypes: ['Sales Order Item'],
      graph: {
        'Sales Order Item': DepGraph(
          doctype: 'Sales Order Item',
          tier: 1,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: {'Sales Order Item'},
      warnings: [],
    );
    var called = false;
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        called = true;
        return const [];
      },
    );
    final engine = PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: fetcher,
      pageSize: 500,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async =>
          DocTypeMeta(name: dt, isTable: true, fields: const []),
    );
    await engine.run(closure);
    expect(called, isFalse);
  });

  test(
    'per-page persistence: a mid-pull failure keeps the last applied page\'s '
    'KEYSET cursor (complete=false) — the reported bug',
    () async {
      // Page 1 applies C-1 and journals its (modified,name). Page 2's Phase-A
      // request throws. The OLD engine deferred the cursor to a full drain, so
      // a failure left the cursor NULL → next pull restarted unfiltered at
      // offset 0 forever (the plateau). The fix journals after EVERY applied
      // page, so the failure keeps a durable complete=false resume point.
      var page = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          page++;
          if (page == 1) {
            return [
              {
                'name': 'C-1',
                'modified': '2026-01-01 00:00:01',
                'customer_name': 'A',
              },
            ];
          }
          throw Exception('network');
        },
      );
      final closure = const ClosureResult(
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
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );
      await engine.run(closure);

      final cursor = await metaDao.getLastOkCursor('Customer');
      expect(
        cursor,
        isNotNull,
        reason:
            'per-page journal must persist after page 1 (defer-to-drain left '
            'this null → restart-from-offset-0 plateau)',
      );
      final parsed = jsonDecode(cursor!) as Map<String, dynamic>;
      expect(parsed['modified'], '2026-01-01 00:00:01');
      expect(parsed['name'], 'C-1');
      expect(
        parsed['complete'],
        isFalse,
        reason: 'an in-progress pull stays resumable, NOT marked complete',
      );
      expect(
        parsed.containsKey('start'),
        isFalse,
        reason: 'no legacy offset is ever persisted',
      );
      // The one successfully-applied row survived.
      expect((await db.query('docs__customer')).length, 1);
    },
  );

  test('multiple doctypes drain in parallel via the pool', () async {
    // Add a second doctype.
    final cMeta = DocTypeMeta(name: 'Lead', fields: [f('lead_name', 'Data')]);
    for (final s in buildParentSchemaDDL(cMeta, tableName: 'docs__lead')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Lead',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__lead',
    });

    final perDoctypeCalls = <String, int>{};
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        perDoctypeCalls[doctype] = (perDoctypeCalls[doctype] ?? 0) + 1;
        // Spec §5.1: server returns rows then an empty page; the engine's
        // exit condition is the empty page.
        if (perDoctypeCalls[doctype] == 1) {
          if (doctype == 'Customer') {
            return [
              {'name': 'C-1', 'modified': '2026-01-01', 'customer_name': 'X'},
            ];
          } else if (doctype == 'Lead') {
            return [
              {'name': 'L-1', 'modified': '2026-01-01', 'lead_name': 'Y'},
            ];
          }
        }
        return const <Map<String, dynamic>>[];
      },
    );
    final closure = const ClosureResult(
      doctypes: ['Customer', 'Lead'],
      graph: {
        'Customer': DepGraph(
          doctype: 'Customer',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
        'Lead': DepGraph(doctype: 'Lead', tier: 0, outgoing: [], incoming: []),
      },
      childDoctypes: {},
      warnings: [],
    );
    final engine = PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: fetcher,
      pageSize: 500,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async => dt == 'Customer'
          ? DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')])
          : DocTypeMeta(name: dt, fields: [f('lead_name', 'Data')]),
    );
    await engine.run(closure);

    expect((await db.query('docs__customer')).length, 1);
    expect((await db.query('docs__lead')).length, 1);
    expect(await metaDao.getLastOkCursor('Customer'), isNotNull);
    expect(await metaDao.getLastOkCursor('Lead'), isNotNull);
  });

  test('WriteQueue is engaged when writeQueueResolver is provided', () async {
    var calls = 0;
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        calls++;
        if (calls <= 2) {
          return [
            {
              'name': 'C-$calls',
              'modified': '2026-01-0$calls',
              'customer_name': 'Row-$calls',
            },
          ];
        }
        return const <Map<String, dynamic>>[];
      },
    );
    final closure = const ClosureResult(
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

    // Capture queue creations: one queue per doctype, reused across pages.
    final created = <String>[];
    final engine = PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: fetcher,
      pageSize: 500,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async =>
          DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      writeQueueResolver: (doctype) {
        created.add(doctype);
        return WriteQueue(db: db, doctype: doctype);
      },
    );
    await engine.run(closure);

    expect(created, [
      'Customer',
    ], reason: 'queue is created once per doctype, not per page');
    final rows = await db.query('docs__customer');
    expect(
      rows.length,
      2,
      reason: 'both pages must commit through the WriteQueue',
    );
  });

  test(
    'parent with child fieldname resolves child meta and pulls children inline',
    () async {
      final orderMeta = DocTypeMeta(
        name: 'Order',
        fields: [f('items', 'Table', options: 'Order Item')],
      );
      final itemMeta = DocTypeMeta(
        name: 'Order Item',
        isTable: true,
        fields: [f('item_code', 'Data'), f('qty', 'Int')],
      );
      for (final s in buildParentSchemaDDL(
        orderMeta,
        tableName: 'docs__order',
      )) {
        await db.execute(s);
      }
      await db.execute('''
        CREATE TABLE docs__order_item (
          mobile_uuid TEXT PRIMARY KEY,
          server_name TEXT,
          parent_uuid TEXT NOT NULL,
          parent_doctype TEXT NOT NULL,
          parentfield TEXT NOT NULL,
          idx INTEGER NOT NULL,
          modified TEXT,
          item_code TEXT,
          qty INTEGER
        )
      ''');
      await db.insert('doctype_meta', {
        'doctype': 'Order',
        'metaJson': '{}',
        'isMobileForm': 0,
        'table_name': 'docs__order',
      });
      await db.insert('doctype_meta', {
        'doctype': 'Order Item',
        'metaJson': '{}',
        'isMobileForm': 0,
        'table_name': 'docs__order_item',
        'is_child_table': 1,
      });

      var calls = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          calls++;
          if (calls == 1) {
            return [
              {
                'name': 'O-1',
                'modified': '2026-01-01',
                'items': [
                  {'item_code': 'A', 'qty': 1},
                  {'item_code': 'B', 'qty': 2},
                ],
              },
            ];
          }
          return const <Map<String, dynamic>>[];
        },
      );
      final closure = const ClosureResult(
        doctypes: ['Order', 'Order Item'],
        graph: {
          'Order': DepGraph(
            doctype: 'Order',
            tier: 0,
            outgoing: [
              DepEdge(
                field: 'items',
                targetDoctype: 'Order Item',
                kind: DepEdgeKind.child,
              ),
            ],
            incoming: [],
          ),
          'Order Item': DepGraph(
            doctype: 'Order Item',
            tier: 1,
            outgoing: [],
            incoming: [],
          ),
        },
        childDoctypes: {'Order Item'},
        warnings: [],
      );
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async => dt == 'Order' ? orderMeta : itemMeta,
      );
      await engine.run(closure);

      expect((await db.query('docs__order')).length, 1);
      final children = await db.query('docs__order_item', orderBy: 'idx ASC');
      expect(children.length, 2);
      expect(children[0]['item_code'], 'A');
      expect(children[1]['item_code'], 'B');
    },
  );

  test(
    'resumes from pre-existing cursor (_decodeJsonOrNull with non-empty string)',
    () async {
      // Pre-seed a complete cursor (complete=true → incremental mode) so the
      // engine resumes with a modified >= filter rather than a fresh offset pull.
      await metaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:00","name":"C-0","complete":true}',
      );
      var calls = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          calls++;
          return calls == 1
              ? [
                  {
                    'name': 'C-1',
                    'modified': '2026-01-02',
                    'customer_name': 'Delta',
                  },
                ]
              : const <Map<String, dynamic>>[];
        },
      );
      final closure = const ClosureResult(
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
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );
      await engine.run(closure);
      final rows = await db.query('docs__customer');
      expect(rows.length, 1);
      final cursorJson = await metaDao.getLastOkCursor('Customer');
      final parsed = jsonDecode(cursorJson!) as Map<String, dynamic>;
      expect(parsed['complete'], isTrue);
    },
  );

  test(
    'allowedDoctypes skips unlisted doctypes without deferring them',
    () async {
      final fetched = <String>[];
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          fetched.add(doctype);
          return const <Map<String, dynamic>>[];
        },
      );
      const closure = ClosureResult(
        doctypes: ['Customer', 'Order'],
        graph: {
          'Customer': DepGraph(
            doctype: 'Customer',
            tier: 0,
            outgoing: [],
            incoming: [],
          ),
          'Order': DepGraph(
            doctype: 'Order',
            tier: 0,
            outgoing: [],
            incoming: [],
          ),
        },
        childDoctypes: {},
        warnings: [],
      );
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );
      final deferred = await engine.run(closure, allowedDoctypes: {'Customer'});
      expect(
        fetched,
        ['Customer'],
        reason: 'Order not in allowedDoctypes — fetcher never called for it',
      );
      expect(
        deferred,
        isEmpty,
        reason: 'allowedDoctypes-filtered doctype is not deferred (SIG-2)',
      );
    },
  );

  test(
    'no truncation: a same-`modified` block larger than pageSize drains fully '
    '(neutralized stall guard)',
    () async {
      // A genuine same-second block of 5 rows, pageSize 2. The OLD stall guard
      // `break`ed the moment a page did not advance `(modified,name)` — which
      // silently TRUNCATED any same-`modified` block bigger than one page. The
      // neutralized guard only logs, and keyset drains the block by `name` one
      // page at a time (Phase A fills, no Phase B), terminating on the empty
      // page. All 5 rows MUST be applied — nothing dropped.
      await metaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:00","name":"C-00","complete":true}',
      );
      final block = List.generate(
        5,
        (i) => {
          'name': 'C-${(i + 1).toString().padLeft(2, '0')}',
          'modified': '2026-01-01 00:00:00',
          'customer_name': 'Row-${i + 1}',
        },
      );
      final server = FakeListServer(block);
      final fetcher = PullPageFetcher(listHttp: server.call);
      final closure = const ClosureResult(
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
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 2,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );
      await engine.run(closure);

      final rows = await db.query('docs__customer', orderBy: 'server_name ASC');
      expect(
        rows.length,
        5,
        reason: 'all 5 same-`modified` rows applied — no page-size truncation',
      );
      expect(
        rows.map((r) => r['server_name']).toList(),
        ['C-01', 'C-02', 'C-03', 'C-04', 'C-05'],
      );
      final parsed =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(parsed['complete'], isTrue);
      expect(parsed['name'], 'C-05');
    },
  );

  test(
    'falls back to normalized table name when doctype_meta has no table_name',
    () async {
      // NULL out table_name → metaDao.getTableName() returns null →
      // PullEngine uses normalizeDoctypeTableName('Customer') = 'docs__customer'.
      await db.update(
        'doctype_meta',
        {'table_name': null},
        where: 'doctype = ?',
        whereArgs: ['Customer'],
      );
      var calls = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          calls++;
          return calls == 1
              ? [
                  {
                    'name': 'C-1',
                    'modified': '2026-01-01',
                    'customer_name': 'Gamma',
                  },
                ]
              : const <Map<String, dynamic>>[];
        },
      );
      final closure = const ClosureResult(
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
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );
      await engine.run(closure);
      final rows = await db.query('docs__customer');
      expect(rows.length, 1);
      expect(rows.first['customer_name'], 'Gamma');
    },
  );

  ClosureResult customerClosure() => const ClosureResult(
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

  PullEngine makeEngine(PullPageFetcher fetcher, {int pageSize = 2}) =>
      PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: pageSize,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );

  test(
    'THE BUG — first sync crashes mid-pull, then RESUMES by keyset (not an '
    'unfiltered offset-0 restart) and completes exactly once',
    () async {
      // 5 rows, unique microsecond `modified` (mirrors migrated Members). A
      // fault-injecting server throws partway through the first pull.
      final data = List.generate(
        5,
        (i) => {
          'name': 'M-${(i + 1).toString().padLeft(2, '0')}',
          'modified': '2026-01-01 00:00:0${i + 1}',
          'customer_name': 'Member ${i + 1}',
        },
      );
      // Fail on call 5 = Phase B of the 3rd logical page. By then pages 1 & 2
      // (M-01..M-04) have each been applied AND journaled.
      final server = FakeListServer(data, throwOnCall: 5);
      final engine = makeEngine(PullPageFetcher(listHttp: server.call));

      // ── First pull: dies mid-flight ────────────────────────────────────
      await engine.run(customerClosure());

      // (i) The cursor was journaled after each successful page — the last
      // durable point is the 2nd page's last row, complete=false.
      final midRaw = await metaDao.getLastOkCursor('Customer');
      expect(midRaw, isNotNull, reason: 'per-page journal, not defer-to-drain');
      final mid = jsonDecode(midRaw!) as Map<String, dynamic>;
      expect(mid['modified'], '2026-01-01 00:00:04');
      expect(mid['name'], 'M-04');
      expect(mid['complete'], isFalse);
      expect(mid.containsKey('start'), isFalse);
      expect(
        (await db.query('docs__customer')).length,
        4,
        reason: 'only the pages that applied before the crash survive',
      );

      // ── Second pull: must RESUME by keyset, not restart from offset 0 ──
      server.reset(); // clear request log + fault; same dataset
      await engine.run(customerClosure());

      // (ii) The FIRST request of the resume is keyset-filtered on the
      // persisted (modified,name) with limit_start 0 — NOT an unfiltered
      // offset-0 restart (the plateau bug).
      final firstResume = server.requests.first;
      expect(
        firstResume['limit_start'],
        0,
        reason: 'keyset — limit_start is never an offset',
      );
      final firstFilters =
          (firstResume['filters'] as List?)?.cast<List>() ?? const [];
      expect(
        firstFilters.any((cl) => cl[0] == 'modified'),
        isTrue,
        reason:
            'resume MUST carry a keyset `modified` filter — not unfiltered '
            'offset-0 (that discard-and-restart IS the reported bug)',
      );
      expect(
        firstFilters,
        contains(equals(['modified', '=', '2026-01-01 00:00:04'])),
        reason: 'Phase A anchored at the persisted watermark',
      );
      // No request in the whole resume ever used a non-zero offset.
      for (final r in server.requests) {
        expect(r['limit_start'], 0);
      }

      // (iii) After resume, every row is present EXACTLY once (no dupes, no
      // gap) and the doctype is marked complete.
      final finalRows =
          await db.query('docs__customer', orderBy: 'server_name ASC');
      expect(finalRows.length, 5, reason: 'full dataset, no gap');
      expect(
        finalRows.map((r) => r['server_name']).toSet().length,
        5,
        reason: 'no duplicate server_name — idempotent apply',
      );
      expect(
        finalRows.map((r) => r['server_name']).toList(),
        ['M-01', 'M-02', 'M-03', 'M-04', 'M-05'],
      );
      final done =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(done['complete'], isTrue);
      expect(done['name'], 'M-05');
    },
  );

  test(
    'incremental seam re-pulls the watermark block by name; idempotent UPSERT '
    'keeps it a no-op count-wise',
    () async {
      // Step 1: initial drain of a single row → doctype goes complete=true.
      final rows = <Map<String, dynamic>>[
        {
          'name': 'M-01',
          'modified': '2026-01-01 00:00:01',
          'customer_name': 'One',
        },
      ];
      final server = FakeListServer(rows);
      final engine = makeEngine(
        PullPageFetcher(listHttp: server.call),
        pageSize: 500,
      );
      await engine.run(customerClosure());
      expect((await db.query('docs__customer')).length, 1);
      final afterInitial =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(afterInitial['complete'], isTrue);

      // Step 2: a delta arrives (M-02). Incremental page 1 is a seam refetch:
      // it re-pulls the whole `modified == watermark` block by name (so it
      // re-fetches the already-applied M-01) then advances to M-02.
      rows.add({
        'name': 'M-02',
        'modified': '2026-01-01 00:00:02',
        'customer_name': 'Two',
      });
      server.reset();
      await engine.run(customerClosure());

      // The seam re-pulled M-01 (Phase A anchored at name > '').
      final seamPhaseA = server.requests.first;
      expect((seamPhaseA['filters'] as List).cast<List>(), [
        ['modified', '=', '2026-01-01 00:00:01'],
        ['name', '>', ''],
      ]);

      // Idempotent: re-applying M-01 did not duplicate it — DB has exactly 2.
      final finalRows =
          await db.query('docs__customer', orderBy: 'server_name ASC');
      expect(finalRows.length, 2);
      expect(finalRows.map((r) => r['server_name']).toList(), ['M-01', 'M-02']);
      final done =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(done['complete'], isTrue);
      expect(done['name'], 'M-02');
    },
  );

  // ── MED-2 (2026-07-23 verify review): the no-advance guard breaks ────────
  //
  // The plan mandated "debugPrint + break" on a non-advancing NON-EMPTY page;
  // an interim build demoted it to log-only. Restoring the break is provably
  // safe under the two-phase keyset (a non-empty page whose last row does not
  // move the cursor means Phase B came back empty ⟹ the doctype is drained)
  // and it cuts the wasteful confirmatory round-trip on the unchanged-doctype
  // incremental seam (MED-3: 2 requests, not 4).

  test(
    'MED-2: unchanged INCREMENTAL doctype breaks on the seam page — 2 HTTP '
    'calls (not 4), terminates, and stays complete=true',
    () async {
      // Enter as INCREMENTAL at the watermark; the server holds exactly the
      // watermark row and NOTHING new. Seam page = Phase A (returns M-01) +
      // Phase B (empty) = 2 calls; the page's last row IS the anchor, so the
      // cursor does not advance → break. Before the fix the loop ran a second
      // confirmatory iteration (Phase A empty + Phase B empty = 2 more calls).
      await metaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:01","name":"M-01","complete":true}',
      );
      final server = FakeListServer([
        {
          'name': 'M-01',
          'modified': '2026-01-01 00:00:01',
          'customer_name': 'One',
        },
      ]);
      final engine = makeEngine(
        PullPageFetcher(listHttp: server.call),
        pageSize: 500,
      );

      await engine.run(customerClosure());

      expect(
        server.callCount,
        2,
        reason:
            'seam Phase A + Phase B only; the restored break skips the '
            'confirmatory 2nd iteration (was 4 calls when the guard only '
            'logged)',
      );
      // Idempotent re-apply of the watermark row — no duplicate.
      expect((await db.query('docs__customer')).length, 1);
      final done =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(
        done['complete'],
        isTrue,
        reason: 'markComplete() runs after the break — doctype stays drained',
      );
      expect(done['name'], 'M-01');
    },
    // A missing break would loop forever against a static server → the
    // timeout makes "terminates" a hard assertion, not a hope.
    timeout: const Timeout(Duration(seconds: 15)),
  );

  test(
    'MED-2 positive: a same-`modified` tie block larger than pageSize drains '
    'FULLY via the `name` tiebreaker — the break never trips mid-block',
    () async {
      // 5 rows sharing one `modified`, pageSize 2. Each keyset page advances
      // the cursor by `name` (C-02, C-04, C-05), so the no-advance guard is
      // NEVER satisfied until the block AND its (empty) Phase-B tail are gone.
      // The break only fires on a genuine non-advance, so nothing is truncated.
      await metaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:00","name":"C-00","complete":true}',
      );
      final block = List.generate(
        5,
        (i) => {
          'name': 'C-${(i + 1).toString().padLeft(2, '0')}',
          'modified': '2026-01-01 00:00:00',
          'customer_name': 'Row-${i + 1}',
        },
      );
      final server = FakeListServer(block);
      final engine = makeEngine(
        PullPageFetcher(listHttp: server.call),
        pageSize: 2,
      );

      await engine.run(customerClosure());

      final rows = await db.query('docs__customer', orderBy: 'server_name ASC');
      expect(
        rows.map((r) => r['server_name']).toList(),
        ['C-01', 'C-02', 'C-03', 'C-04', 'C-05'],
        reason: 'all 5 tie rows applied — the restored break did not truncate',
      );
      expect(
        server.callCount,
        greaterThan(2),
        reason:
            'the block drained across multiple keyset pages; a premature '
            'break at the first page would have fetched far fewer',
      );
      final done =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(done['complete'], isTrue);
      expect(done['name'], 'C-05');
    },
    timeout: const Timeout(Duration(seconds: 15)),
  );
}
