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

    final meta = DocTypeMeta(name: 'Customer', fields: [
      f('customer_name', 'Data'),
    ]);
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
    final closure = ClosureResult(
      doctypes: const ['Customer'],
      graph: const {
        'Customer': DepGraph(
          doctype: 'Customer',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: const {},
      warnings: const [],
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
      payload: '{}',
    );
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        fail('fetcher should not be called for a deferred doctype');
      },
    );
    final closure = ClosureResult(
      doctypes: const ['Customer'],
      graph: const {
        'Customer': DepGraph(
          doctype: 'Customer',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: const {},
      warnings: const [],
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
      metaResolver: (dt) async =>
          DocTypeMeta(name: dt, fields: const []),
    );
    await engine.run(closure);
    expect(notifier.value.perDoctype['Customer']!.deferred, isTrue);
  });

  test('skips child doctypes (they ride with parent)', () async {
    final closure = ClosureResult(
      doctypes: const ['Sales Order Item'],
      graph: const {
        'Sales Order Item': DepGraph(
          doctype: 'Sales Order Item',
          tier: 1,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: const {'Sales Order Item'},
      warnings: const [],
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

  test('does not advance cursor on mid-page failure', () async {
    var page = 0;
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        page++;
        if (page == 1) {
          return [
            {
              'name': 'C-1',
              'modified': '2026-01-01',
              'customer_name': 'A',
            },
          ];
        }
        throw Exception('network');
      },
    );
    final closure = ClosureResult(
      doctypes: const ['Customer'],
      graph: const {
        'Customer': DepGraph(
          doctype: 'Customer',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: const {},
      warnings: const [],
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
    expect(cursor, isNull,
        reason: 'cursor must NOT advance when page 2 throws');
  });

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
              {
                'name': 'C-1',
                'modified': '2026-01-01',
                'customer_name': 'X',
              },
            ];
          } else if (doctype == 'Lead') {
            return [
              {
                'name': 'L-1',
                'modified': '2026-01-01',
                'lead_name': 'Y',
              },
            ];
          }
        }
        return const <Map<String, dynamic>>[];
      },
    );
    final closure = ClosureResult(
      doctypes: const ['Customer', 'Lead'],
      graph: const {
        'Customer': DepGraph(
          doctype: 'Customer',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
        'Lead': DepGraph(
          doctype: 'Lead',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: const {},
      warnings: const [],
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
    final closure = ClosureResult(
      doctypes: const ['Customer'],
      graph: const {
        'Customer': DepGraph(
          doctype: 'Customer',
          tier: 0,
          outgoing: [],
          incoming: [],
        ),
      },
      childDoctypes: const {},
      warnings: const [],
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

    expect(
      created,
      ['Customer'],
      reason: 'queue is created once per doctype, not per page',
    );
    final rows = await db.query('docs__customer');
    expect(rows.length, 2,
        reason: 'both pages must commit through the WriteQueue');
  });

  test(
    'parent with child fieldname resolves child meta and pulls children inline',
    () async {
      final orderMeta = DocTypeMeta(name: 'Order', fields: [
        f('items', 'Table', options: 'Order Item'),
      ]);
      final itemMeta = DocTypeMeta(
        name: 'Order Item',
        isTable: true,
        fields: [f('item_code', 'Data'), f('qty', 'Int')],
      );
      for (final s in buildParentSchemaDDL(orderMeta, tableName: 'docs__order')) {
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
      final closure = ClosureResult(
        doctypes: const ['Order', 'Order Item'],
        graph: const {
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
        childDoctypes: const {'Order Item'},
        warnings: const [],
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
            dt == 'Order' ? orderMeta : itemMeta,
      );
      await engine.run(closure);

      expect((await db.query('docs__order')).length, 1);
      final children = await db.query('docs__order_item', orderBy: 'idx ASC');
      expect(children.length, 2);
      expect(children[0]['item_code'], 'A');
      expect(children[1]['item_code'], 'B');
    },
  );
}
