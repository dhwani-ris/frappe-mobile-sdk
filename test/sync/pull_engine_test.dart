import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state.dart';
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

/// Adapts a plain-rows fake to the [ListHttpFn] page shape. `namesScanned` is
/// left null, matching the flat `get_list` path where every listed row is
/// returned.
ListHttpFn rowsFake(
  Future<List<Map<String, dynamic>>> Function(String, Map<String, Object?>) fn,
) =>
    (d, p) async => ListHttpPage(await fn(d, p));

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

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
      listHttp: rowsFake((doctype, params) async {
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
      }),
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
      listHttp: rowsFake((doctype, params) async {
        fail('fetcher should not be called for a deferred doctype');
      }),
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
      listHttp: rowsFake((doctype, params) async => const []),
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
      listHttp: rowsFake((doctype, params) async {
        called = true;
        return const [];
      }),
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
    'mid-page failure leaves a resumable checkpoint (complete:false)',
    () async {
      var page = 0;
      final fetcher = PullPageFetcher(
        listHttp: rowsFake((doctype, params) async {
          page++;
          if (page == 1) {
            return [
              {'name': 'C-1', 'modified': '2026-01-01', 'customer_name': 'A'},
            ];
          }
          throw Exception('network');
        }),
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
        reason: 'page 1 succeeded — its progress must be a durable checkpoint',
      );
      final parsed = jsonDecode(cursor!) as Map<String, dynamic>;
      expect(
        parsed['complete'],
        isFalse,
        reason: 'drain was interrupted — not yet incremental',
      );
      expect(
        parsed['name'],
        'C-1',
        reason: 'checkpoint is positioned at the last applied row',
      );
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
      listHttp: rowsFake((doctype, params) async {
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
      }),
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

  test(
    'a doctype whose meta cannot be resolved is skipped, not fatal to the pull',
    () async {
      // Regression: a getDocTypeMeta 500 (e.g. a doctype missing its server
      // controller module) previously escaped _runDoctype -> Future.wait
      // rethrew -> run() aborted, stranding every OTHER doctype. It must now
      // skip the bad doctype and still pull the rest.
      var custCalls = 0;
      final fetcher = PullPageFetcher(
        listHttp: rowsFake((doctype, params) async {
          if (doctype == 'Customer') {
            custCalls++;
            return custCalls == 1
                ? [
                    {
                      'name': 'C-1',
                      'modified': '2026-01-01',
                      'customer_name': 'X',
                    },
                  ]
                : const <Map<String, dynamic>>[];
          }
          return const <Map<String, dynamic>>[];
        }),
      );
      final closure = const ClosureResult(
        doctypes: ['Machinery Flow', 'Customer'],
        graph: {
          'Machinery Flow': DepGraph(
            doctype: 'Machinery Flow',
            tier: 0,
            outgoing: [],
            incoming: [],
          ),
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
        metaResolver: (dt) async {
          if (dt == 'Machinery Flow') {
            throw Exception(
              "No module named 'prime_rural...machinery_flow' (Status: 500)",
            );
          }
          return DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]);
        },
      );

      // Must NOT throw despite Machinery Flow's meta failure.
      await engine.run(closure);

      // The healthy doctype still pulled fully.
      expect((await db.query('docs__customer')).length, 1);
      expect(await metaDao.getLastOkCursor('Customer'), isNotNull);
      expect(notifier.value.perDoctype['Customer']!.completedAt, isNotNull);

      // The failing doctype was skipped: recorded as failed, never completed.
      final mf = notifier.value.perDoctype['Machinery Flow'];
      expect(mf, isNotNull);
      expect(mf!.note, contains('failed (meta)'));
      expect(mf.completedAt, isNull);
      // Observable in RELEASE too: recorded on SyncState.failedMetaSyncs, not
      // just the debug-only sdkLog / the unread per-doctype `note`.
      expect(notifier.value.failedMetaSyncs, contains('Machinery Flow'));
      // Marked deferred so the progress UI doesn't render it as perpetually
      // in-progress (it reads deferred + completedAt only).
      expect(mf.deferred, isTrue);
    },
  );

  test('WriteQueue is engaged when writeQueueResolver is provided', () async {
    var calls = 0;
    final fetcher = PullPageFetcher(
      listHttp: rowsFake((doctype, params) async {
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
      }),
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
        listHttp: rowsFake((doctype, params) async {
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
        }),
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
    'a child doctype whose meta fails skips only that child edge — the parent '
    'still pulls its own scalar row (not aborted)',
    () async {
      final orderMeta = DocTypeMeta(
        name: 'Order',
        fields: [f('items', 'Table', options: 'Order Item')],
      );
      for (final s in buildParentSchemaDDL(
        orderMeta,
        tableName: 'docs__order',
      )) {
        await db.execute(s);
      }
      await db.insert('doctype_meta', {
        'doctype': 'Order',
        'metaJson': '{}',
        'isMobileForm': 0,
        'table_name': 'docs__order',
      });
      var orderCalls = 0;
      final fetcher = PullPageFetcher(
        listHttp: rowsFake((doctype, params) async {
          if (doctype == 'Order') {
            orderCalls++;
            return orderCalls == 1
                ? const [
                    {'name': 'O-1', 'modified': '2026-01-01'},
                  ]
                : const <Map<String, dynamic>>[];
          }
          return const <Map<String, dynamic>>[];
        }),
      );
      const closure = ClosureResult(
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
      final notifier = SyncStateNotifier();
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 500,
        notifier: notifier,
        metaResolver: (dt) async {
          if (dt == 'Order Item') {
            throw Exception('child meta 500');
          }
          return orderMeta;
        },
      );

      // Must NOT throw despite the child meta failure.
      await engine.run(closure);

      // Parent still pulled its own scalar row (not aborted by the child).
      expect((await db.query('docs__order')).length, 1);
      expect(notifier.value.perDoctype['Order']!.completedAt, isNotNull);
      // The failing CHILD is recorded observably.
      expect(notifier.value.failedMetaSyncs, contains('Order Item'));
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
        listHttp: rowsFake((doctype, params) async {
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
        }),
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
        listHttp: rowsFake((doctype, params) async {
          fetched.add(doctype);
          return const <Map<String, dynamic>>[];
        }),
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
    'stall guard: terminates and persists cursor when all page rows share same modified',
    () async {
      // Simulates INCREMENTAL sync where every row has the same `modified`
      // timestamp (e.g. bulk-imported reference data). Without the stall guard,
      // `modified >= cursor.modified` returns the same page forever.
      // The stall guard only fires for complete=true cursors; seed one first.
      await metaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2025-12-31","name":"C-0","complete":true}',
      );
      var calls = 0;
      final fetcher = PullPageFetcher(
        listHttp: rowsFake((doctype, params) async {
          calls++;
          // Return the same 3 rows on every call — cursor never advances.
          // The stall guard must break the loop after the second fetch.
          return [
            {
              'name': 'C-1',
              'modified': '2026-01-01 00:00:00',
              'customer_name': 'Alpha',
            },
            {
              'name': 'C-2',
              'modified': '2026-01-01 00:00:00',
              'customer_name': 'Beta',
            },
            {
              'name': 'C-3',
              'modified': '2026-01-01 00:00:00',
              'customer_name': 'Gamma',
            },
          ];
        }),
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

      // Must terminate (not loop forever).
      // Exactly 2 fetches: one fresh page + one stall detection.
      expect(calls, 2, reason: 'stall detected on second fetch — loop exits');
      // Rows are idempotently applied.
      final rows = await db.query('docs__customer');
      expect(rows.length, 3);
      // Cursor is persisted with complete:true so the next sync cycle
      // resumes incrementally rather than from scratch.
      final cursorJson = await metaDao.getLastOkCursor('Customer');
      expect(cursorJson, isNotNull);
      final parsed = jsonDecode(cursorJson!) as Map<String, dynamic>;
      expect(parsed['complete'], isTrue);
    },
  );

  group('permission-filtered pages must not end the drain', () {
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

    PullEngine engineWith(PullPageFetcher fetcher) => PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 1),
      fetcher: fetcher,
      pageSize: 2,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async =>
          DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
    );

    test('initial drain skips a fully-filtered page and keeps going', () async {
      // The listFullDocs path resolves names through a per-doc permission gate
      // that silently drops denied/missing names. A page whose names are ALL
      // dropped returns zero docs — previously indistinguishable from
      // end-of-stream, so the engine stopped here and marked the doctype fully
      // drained. Every later page was then never fetched, and because the
      // doctype flipped to incremental it would never re-drain: silent,
      // permanent data loss.
      var calls = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          calls++;
          switch (calls) {
            case 1:
              return const ListHttpPage([
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
              ], namesScanned: 2);
            case 2:
              // Whole page filtered out.
              return const ListHttpPage([], namesScanned: 2);
            case 3:
              return const ListHttpPage([
                {
                  'name': 'C-5',
                  'modified': '2026-01-05 00:00:00',
                  'customer_name': 'Epsilon',
                },
              ], namesScanned: 1);
            default:
              return const ListHttpPage([], namesScanned: 0);
          }
        },
      );
      await engineWith(fetcher).run(closure);

      expect(
        calls,
        4,
        reason: 'the filtered page must be skipped, not treated as the end',
      );
      final names = (await db.query(
        'docs__customer',
        orderBy: 'server_name',
      )).map((r) => r['server_name']).toList();
      expect(names, [
        'C-1',
        'C-2',
        'C-5',
      ], reason: 'the row behind the filtered page must still be pulled');
    });

    test(
      'the skipped page advances limit_start by names scanned, not docs returned',
      () async {
        final starts = <int?>[];
        var calls = 0;
        final fetcher = PullPageFetcher(
          listHttp: (doctype, params) async {
            starts.add(params['limit_start'] as int?);
            calls++;
            if (calls == 1) return const ListHttpPage([], namesScanned: 2);
            return const ListHttpPage([], namesScanned: 0);
          },
        );
        await engineWith(fetcher).run(closure);
        expect(starts, [0, 2]);
      },
    );

    test('H3 regression: a fully-denied incremental window advances the '
        'watermark past itself and the drain keeps going', () async {
      await metaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:00","name":"C-1","complete":true}',
      );
      var calls = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          calls++;
          switch (calls) {
            case 1:
              // Every name in the window was dropped by the per-doc
              // permission gate. `limit_start` is pinned at 0 in
              // incremental mode, so the watermark itself has to move.
              return const ListHttpPage(
                [],
                namesScanned: 2,
                scannedMaxModified: '2026-01-02 00:00:00',
                scannedMaxName: 'C-3',
              );
            case 2:
              // The row hiding BEHIND the denied block.
              return const ListHttpPage([
                {
                  'name': 'C-9',
                  'modified': '2026-01-09 00:00:00',
                  'customer_name': 'Iota',
                },
              ], namesScanned: 1);
            default:
              return const ListHttpPage([], namesScanned: 0);
          }
        },
      );
      await engineWith(fetcher).run(closure);

      expect(
        calls,
        3,
        reason:
            'before the fix this stopped at call 1: the fetcher returned '
            'the cursor unchanged, the engine broke on `scratch.complete`, '
            'markComplete() re-persisted the identical watermark, and the '
            'next cycle issued the byte-identical query — C-9 was never '
            'fetched and every row behind the denied block stayed silently '
            'and permanently unreachable',
      );
      final names = (await db.query(
        'docs__customer',
        orderBy: 'server_name',
      )).map((r) => r['server_name']).toList();
      expect(
        names,
        contains('C-9'),
        reason: 'the row behind the denied block must still be pulled',
      );
      final parsed =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(
        parsed['modified'],
        '2026-01-09 00:00:00',
        reason:
            'the watermark must end up past the denied block, not frozen '
            'at 2026-01-01 00:00:00 forever',
      );
    });

    test(
      'a same-second filtered window still stops (nothing to advance to)',
      () async {
        await metaDao.setLastOkCursor(
          'Customer',
          '{"modified":"2026-01-01 00:00:00","name":"C-1","complete":true}',
        );
        var calls = 0;
        final fetcher = PullPageFetcher(
          listHttp: (doctype, params) async {
            calls++;
            // The whole scanned window sits inside the cursor's own
            // `modified` second, so there is no strictly-greater watermark
            // to move to and the fetcher reports pageFiltered: false.
            return const ListHttpPage(
              [],
              namesScanned: 2,
              scannedMaxModified: '2026-01-01 00:00:00',
              scannedMaxName: 'C-3',
            );
          },
        );
        await engineWith(fetcher).run(closure);

        expect(
          calls,
          1,
          reason:
              'the watermark cannot advance here, so continuing would '
              're-request the same window forever — this is the '
              'anti-infinite-loop guarantee, and the test hanging means the '
              'skip guard is wrong',
        );
        final parsed =
            jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
                as Map<String, dynamic>;
        expect(
          parsed['modified'],
          '2026-01-01 00:00:00',
          reason:
              'the watermark is left where it was, so the window is '
              'retried next cycle',
        );
        expect(
          parsed['name'],
          'C-1',
          reason:
              '`name` must never advance without `modified`: SyncService '
              'drops rows with modified == cursor.modified && name <= '
              'cursor.name, so bumping `name` alone would skip READABLE rows',
        );
      },
    );

    test('the skip is checkpointed against a later failure', () async {
      await metaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01 00:00:00","name":"C-1","complete":true}',
      );
      var calls = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          calls++;
          if (calls == 1) {
            return const ListHttpPage(
              [],
              namesScanned: 2,
              scannedMaxModified: '2026-01-02 00:00:00',
              scannedMaxName: 'C-3',
            );
          }
          throw Exception('boom');
        },
      );
      // PullEngine catches a mid-pull failure and records it per doctype;
      // run() does not rethrow.
      await engineWith(fetcher).run(closure);

      expect(calls, 2, reason: 'the engine skipped past the denied window');
      final parsed =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!)
              as Map<String, dynamic>;
      expect(
        parsed['modified'],
        '2026-01-02 00:00:00',
        reason:
            'the mid-loop skip checkpoint must survive the failure on the '
            'NEXT page — without it the cursor falls back to '
            '2026-01-01 00:00:00 and the whole denied block is re-scanned '
            'every cycle',
      );
    });
  });

  group('a server refusal is deferred, not a permanent failure', () {
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

    Future<DoctypeSyncState?> runWith(Object error) async {
      final notifier = SyncStateNotifier();
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 1),
        fetcher: PullPageFetcher(listHttp: (_, _) async => throw error),
        pageSize: 10,
        notifier: notifier,
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );
      await engine.run(closure);
      return notifier.value.perDoctype['Customer'];
    }

    test('403 is reported as deferred', () async {
      // The closure pull is intentionally no longer gated on client-side
      // canRead, so a genuinely forbidden doctype is requested every cycle and
      // refused every time. That is a steady state, not a fault — a host
      // rendering per-doctype state must not show a permanent red "failed".
      final st = await runWith(AuthException('not permitted', 403));
      expect(st, isNotNull);
      expect(st!.deferred, isTrue);
      expect(st.note, contains('403'));
    });

    test(
      'a 403 delivered as ApiException (non-JSON body) is also deferred',
      () async {
        final st = await runWith(ApiException('<h1>403</h1>', 403));
        expect(st!.deferred, isTrue);
      },
    );

    test('a real fault is still reported as failed', () async {
      for (final e in <Object>[
        ApiException('boom', 500),
        NetworkException('No internet connection'),
        Exception('schema mismatch'),
      ]) {
        final st = await runWith(e);
        expect(st!.deferred, isFalse, reason: '$e must not be deferred');
        expect(st.note, contains('failed'));
      }
    });
  });

  group('demotion out of the mobile-form set is narrow', () {
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

    /// Marks Customer as a mobile form, fails its pull with [error], and
    /// reports whether it survived in the mobile-form set.
    Future<bool> stillMobileFormAfter(Object error) async {
      await db.update(
        'doctype_meta',
        {'isMobileForm': 1},
        where: 'doctype = ?',
        whereArgs: ['Customer'],
      );
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 1),
        fetcher: PullPageFetcher(listHttp: (_, _) async => throw error),
        pageSize: 10,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );
      await engine.run(closure);
      final rows = await db.query(
        'doctype_meta',
        columns: ['isMobileForm'],
        where: 'doctype = ?',
        whereArgs: ['Customer'],
      );
      return rows.single['isMobileForm'] == 1;
    }

    // The regression this pins: `bulkGetWithChildren` throws
    // ApiException(…, 502) for a truncated / proxy-mangled 2xx body. Treating
    // 502 as terminal meant ONE malformed response silently cost the user the
    // form — it leaves `getMobileFormDoctypeNames()` (the closure's entry-point
    // source) AND the workspace, and only a login / initialize() re-promotes.
    test('a 502 from the malformed-batch guard does NOT demote', () async {
      expect(
        await stillMobileFormAfter(ApiException('malformed batch body', 502)),
        isTrue,
        reason:
            'a truncated response is transient — demoting costs the user the '
            'form until app restart, which is worse than re-requesting it',
      );
    });

    test('a gateway 503 / 504 does NOT demote', () async {
      expect(
        await stillMobileFormAfter(ApiException('bad gateway', 503)),
        isTrue,
      );
      expect(
        await stillMobileFormAfter(ApiException('gateway timeout', 504)),
        isTrue,
      );
    });

    test('a transport failure does NOT demote', () async {
      expect(
        await stillMobileFormAfter(NetworkException('No internet connection')),
        isTrue,
      );
    });

    // The other direction, so the narrowing above cannot silently disable
    // demotion altogether: a 500 is the measured broken-controller case and
    // recurs identically on every sweep, so it must still stop being requested.
    test('a 500 (broken controller) DOES demote', () async {
      expect(
        await stillMobileFormAfter(ApiException('no module named …', 500)),
        isFalse,
      );
    });

    test('a 403 (read denied) DOES demote', () async {
      expect(
        await stillMobileFormAfter(AuthException('not permitted', 403)),
        isFalse,
      );
    });
  });

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
        listHttp: rowsFake((doctype, params) async {
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
        }),
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

  test(
    'resumes from the persisted offset after a crash (no re-download)',
    () async {
      const rows = [
        {'name': 'C-1', 'modified': '2026-01-01', 'customer_name': 'A'},
        {'name': 'C-2', 'modified': '2026-01-02', 'customer_name': 'B'},
      ];
      List<Map<String, dynamic>> pageAt(int start) =>
          start >= rows.length ? const [] : [rows[start]];

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
      PullEngine engineWith(PullPageFetcher fetcher) => PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: fetcher,
        pageSize: 1,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('customer_name', 'Data')]),
      );

      // Run 1: applies page at offset 0, then "crashes" on the next fetch.
      var run1Calls = 0;
      await engineWith(
        PullPageFetcher(
          listHttp: rowsFake((doctype, params) async {
            run1Calls++;
            if (run1Calls >= 2) throw Exception('crash');
            return pageAt(params['limit_start'] as int);
          }),
        ),
      ).run(closure);

      expect(
        (await db.query('docs__customer')).length,
        1,
        reason: 'only the first page was applied before the crash',
      );

      // Run 2: fresh engine, same DB. Must start from limit_start == 1.
      final observedStarts = <int>[];
      await engineWith(
        PullPageFetcher(
          listHttp: rowsFake((doctype, params) async {
            final start = params['limit_start'] as int;
            observedStarts.add(start);
            return pageAt(start);
          }),
        ),
      ).run(closure);

      expect(
        observedStarts.first,
        1,
        reason:
            'resume must continue from the persisted offset, not re-pull '
            'page 0',
      );
      expect((await db.query('docs__customer')).length, 2);
      final parsed =
          jsonDecode((await metaDao.getLastOkCursor('Customer'))!) as Map;
      expect(
        parsed['complete'],
        isTrue,
        reason: 'doctype fully drained on the second run',
      );
    },
  );
  test('demotes a mobile form from the set on a terminal data 403', () async {
    // A form this user's role cannot read: its list fetch 403s. It must be
    // dropped from the mobile-form set so isOfflineBootstrapComplete and the
    // workspace stop requiring/showing a form that can never load.
    final metaX = DocTypeMeta(name: 'X', fields: [f('title', 'Data')]);
    for (final s in buildParentSchemaDDL(metaX, tableName: 'docs__x')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'X',
      'metaJson': '{"name":"X"}',
      'isMobileForm': 1,
      'table_name': 'docs__x',
    });
    final engine = PullEngine(
      db: db,
      metaDao: metaDao,
      outboxDao: OutboxDao(db),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: PullPageFetcher(
        listHttp: (doctype, params) async =>
            throw AuthException('Insufficient Permission for X', 403),
      ),
      pageSize: 500,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async =>
          DocTypeMeta(name: dt, fields: [f('title', 'Data')]),
    );
    await engine.run(
      const ClosureResult(
        doctypes: ['X'],
        graph: {
          'X': DepGraph(doctype: 'X', tier: 0, outgoing: [], incoming: []),
        },
        childDoctypes: {},
        warnings: [],
      ),
    );

    final row = await metaDao.findByDoctype('X');
    expect(row, isNotNull);
    expect(
      row!.isMobileForm,
      isFalse,
      reason: 'a read-denied (403) mobile form must be demoted',
    );
  });

  test(
    'does NOT demote a mobile form on a transient network failure',
    () async {
      final metaY = DocTypeMeta(name: 'Y', fields: [f('title', 'Data')]);
      for (final s in buildParentSchemaDDL(metaY, tableName: 'docs__y')) {
        await db.execute(s);
      }
      await db.insert('doctype_meta', {
        'doctype': 'Y',
        'metaJson': '{"name":"Y"}',
        'isMobileForm': 1,
        'table_name': 'docs__y',
      });
      final engine = PullEngine(
        db: db,
        metaDao: metaDao,
        outboxDao: OutboxDao(db),
        pool: ConcurrencyPool(maxConcurrent: 2),
        fetcher: PullPageFetcher(
          listHttp: (doctype, params) async =>
              throw NetworkException('Cannot reach server'),
        ),
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (dt) async =>
            DocTypeMeta(name: dt, fields: [f('title', 'Data')]),
      );
      await engine.run(
        const ClosureResult(
          doctypes: ['Y'],
          graph: {
            'Y': DepGraph(doctype: 'Y', tier: 0, outgoing: [], incoming: []),
          },
          childDoctypes: {},
          warnings: [],
        ),
      );

      final row = await metaDao.findByDoctype('Y');
      expect(
        row!.isMobileForm,
        isTrue,
        reason: 'a transient network failure must NOT demote the form',
      );
    },
  );
}
