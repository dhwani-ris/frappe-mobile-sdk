import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/response_writeback.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao outbox;

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
    final parentMeta = DocTypeMeta(
      name: 'Sales Order',
      fields: [f('items', 'Table', options: 'SO Item')],
    );
    final childMeta = DocTypeMeta(
      name: 'SO Item',
      isTable: true,
      fields: [f('qty', 'Int')],
    );
    for (final s in buildParentSchemaDDL(
      parentMeta,
      tableName: 'docs__sales_order',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      childMeta,
      tableName: 'docs__so_item',
    )) {
      await db.execute(s);
    }

    outbox = OutboxDao(db);
    await db.insert('docs__sales_order', {
      'mobile_uuid': 'u-so',
      'sync_status': 'dirty',
      'local_modified': 1,
    });
    await db.insert('docs__so_item', {
      'mobile_uuid': 'c-1',
      'parent_uuid': 'u-so',
      'parent_doctype': 'Sales Order',
      'parentfield': 'items',
      'idx': 0,
      'qty': 2,
    });
    await outbox.insertPending(
      doctype: 'Sales Order',
      mobileUuid: 'u-so',
      operation: OutboxOperation.insert,
    );
  });

  tearDown(() async => db.close());

  test('writes parent server_name + modified, marks synced', () async {
    final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
    await ResponseWriteback.apply(
      db: db,
      row: outboxRow,
      parentTable: 'docs__sales_order',
      childTablesByFieldname: const {'items': 'docs__so_item'},
      response: {
        'name': 'SO-1001',
        'modified': '2026-02-01 10:00:00',
        'items': [
          {'name': 'SOIT-1', 'idx': 0, 'modified': '2026-02-01 10:00:00'},
        ],
      },
    );
    final p = (await db.query('docs__sales_order')).first;
    expect(p['server_name'], 'SO-1001');
    expect(p['modified'], '2026-02-01 10:00:00');
    expect(p['sync_status'], 'synced');
    final c = (await db.query('docs__so_item')).first;
    expect(c['server_name'], 'SOIT-1');
  });

  test(
    'writeback deletes the outbox row + writes server_name to docs__',
    () async {
      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      await ResponseWriteback.apply(
        db: db,
        row: outboxRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {},
        response: {'name': 'SO-1001', 'modified': '2026-02-01'},
      );
      // Slim outbox: markDone deletes the row outright (Invariant 2).
      expect(await outbox.findById(outboxRow.id), isNull);
      // server_name lives on docs__<doctype>.
      final docRow = (await db.query('docs__sales_order')).first;
      expect(docRow['server_name'], 'SO-1001');
      expect(docRow['sync_status'], 'synced');
    },
  );

  test(
    'DELETE early-exit: hard-deletes parent, children, and outbox row',
    () async {
      final deleteRowId = await outbox.insertPending(
        doctype: 'Sales Order',
        mobileUuid: 'u-so',
        operation: OutboxOperation.delete,
      );
      final deleteRow = (await outbox.findById(deleteRowId))!;
      await ResponseWriteback.apply(
        db: db,
        row: deleteRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {'items': 'docs__so_item'},
        response: const <String, dynamic>{},
      );
      expect(await db.query('docs__sales_order'), isEmpty);
      expect(await db.query('docs__so_item'), isEmpty);
      expect(await outbox.findById(deleteRowId), isNull);
    },
  );

  test(
    'throws ServerRejection when response has neither name nor docname',
    () async {
      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      expect(
        () => ResponseWriteback.apply(
          db: db,
          row: outboxRow,
          parentTable: 'docs__sales_order',
          childTablesByFieldname: const {},
          response: const <String, dynamic>{
            // no 'name', no 'docname'
            'modified': '2026-01-01',
          },
        ),
        throwsA(isA<ServerRejection>()),
      );
    },
  );

  test('falls back to docname when name is missing', () async {
    final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
    await ResponseWriteback.apply(
      db: db,
      row: outboxRow,
      parentTable: 'docs__sales_order',
      childTablesByFieldname: const {},
      response: const {'docname': 'T-99', 'modified': '2026-01-01 00:00:00'},
    );
    final updated = (await db.query('docs__sales_order')).first;
    expect(updated['server_name'], 'T-99');
  });

  test(
    'matches children by position when server idx mismatches local idx',
    () async {
      // Reproduces the Frappe idx renumbering quirk: SDK sends children
      // with idx=0,1 (zero-indexed by `LocalWriter`); Frappe's
      // `base_document.append` overwrites idx=0 → 1 because
      // `getattr(d, "idx", False)` treats 0 as falsy. The response then
      // has idx=1,2. A literal `WHERE idx = cm['idx']` would miss every
      // local row; positional fallback recovers it.
      await db.insert('docs__so_item', {
        'mobile_uuid': 'c-2',
        'parent_uuid': 'u-so',
        'parent_doctype': 'Sales Order',
        'parentfield': 'items',
        'idx': 1,
        'qty': 5,
      });
      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      await ResponseWriteback.apply(
        db: db,
        row: outboxRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {'items': 'docs__so_item'},
        response: {
          'name': 'SO',
          'modified': '2026-02-01',
          'items': [
            {'name': 'A', 'idx': 1, 'modified': '2026-02-01'},
            {'name': 'B', 'idx': 2, 'modified': '2026-02-01'},
          ],
        },
      );
      final rows = await db.query('docs__so_item', orderBy: 'idx ASC');
      expect(rows[0]['server_name'], 'A');
      expect(rows[1]['server_name'], 'B');
    },
  );

  test(
    'warns when a server child matches no local row (double-miss)',
    () async {
      // No echoed mobile_uuid and no local row at the fallback position →
      // both the mobile_uuid match and the (parent_uuid, parentfield, idx)
      // fallback return 0. The writeback for this child is silently dropped;
      // surface it so it is not invisible (H2).
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      try {
        await ResponseWriteback.apply(
          db: db,
          row: outboxRow,
          parentTable: 'docs__sales_order',
          childTablesByFieldname: const {'items': 'docs__so_item'},
          response: {
            'name': 'SO',
            'modified': '2026-02-01',
            'items': [
              // pos 0 → matches local idx 0 (c-1): no warning.
              {'name': 'A', 'idx': 0, 'modified': '2026-02-01'},
              // pos 1 → no echoed uuid, no local idx=1 row: double-miss.
              {'name': 'ORPHAN', 'idx': 99, 'modified': '2026-02-01'},
            ],
          },
        );
      } finally {
        debugPrint = original;
      }
      // The matched row still got its server_name.
      final matched = (await db.query(
        'docs__so_item',
        where: 'mobile_uuid = ?',
        whereArgs: ['c-1'],
      )).first;
      expect(matched['server_name'], 'A');
      // The orphan child produced exactly one warning naming it.
      final warnings = logs
          .where((l) => l.contains('ResponseWriteback') && l.contains('ORPHAN'))
          .toList();
      expect(warnings, hasLength(1));
    },
  );

  test(
    'prefers mobile_uuid match over position when server echoes it',
    () async {
      // mobile_control's _ensure_mobile_uuid_field round-trips
      // mobile_uuid for child rows. When present, use it — robust even
      // if the response order differs from local order.
      await db.insert('docs__so_item', {
        'mobile_uuid': 'c-2',
        'parent_uuid': 'u-so',
        'parent_doctype': 'Sales Order',
        'parentfield': 'items',
        'idx': 1,
        'qty': 5,
      });
      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      // Server response is in REVERSE order vs local (c-2 then c-1).
      // Without the mobile_uuid match, position would assign A → c-1
      // and B → c-2. With it, A → c-2 and B → c-1 because the response
      // carries mobile_uuid for each row.
      await ResponseWriteback.apply(
        db: db,
        row: outboxRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {'items': 'docs__so_item'},
        response: {
          'name': 'SO',
          'modified': '2026-02-01',
          'items': [
            {
              'name': 'A',
              'idx': 1,
              'mobile_uuid': 'c-2',
              'modified': '2026-02-01',
            },
            {
              'name': 'B',
              'idx': 2,
              'mobile_uuid': 'c-1',
              'modified': '2026-02-01',
            },
          ],
        },
      );
      final rows = await db.query('docs__so_item', orderBy: 'mobile_uuid ASC');
      final byUuid = {for (final r in rows) r['mobile_uuid']: r['server_name']};
      expect(byUuid['c-1'], 'B');
      expect(byUuid['c-2'], 'A');
    },
  );

  // Frappe's server-owned audit fields (`owner`, `creation`, `modified_by`)
  // are stripped from every OUTBOUND payload, so the push response is the
  // only place a client learns what the server assigned to a doc it created
  // offline. The writeback used to drop them, which left `owner = NULL` on a
  // successfully-pushed row — and since `FilterParser` now emits real SQL for
  // an `owner = <me>` clause, the creating user's own record disappeared from
  // their list until the next full pull.
  group('server-owned audit fields', () {
    test('persists owner / creation / modified_by from the response', () async {
      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      await ResponseWriteback.apply(
        db: db,
        row: outboxRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {'items': 'docs__so_item'},
        response: {
          'name': 'SO-1001',
          'modified': '2026-02-01 10:00:00',
          'owner': 'alice@example.com',
          'creation': '2026-01-31 09:00:00',
          'modified_by': 'bob@example.com',
          'items': [
            {'name': 'SOIT-1', 'idx': 0, 'modified': '2026-02-01 10:00:00'},
          ],
        },
      );

      final p = (await db.query('docs__sales_order')).first;
      expect(p['owner'], 'alice@example.com');
      expect(p['creation'], '2026-01-31 09:00:00');
      expect(p['modified_by'], 'bob@example.com');
      // The pre-existing writeback must be untouched by the addition.
      expect(p['server_name'], 'SO-1001');
      expect(p['modified'], '2026-02-01 10:00:00');
      expect(p['sync_status'], 'synced');
      expect(p['sync_attempts'], 0);
      final c = (await db.query('docs__so_item')).first;
      expect(c['server_name'], 'SOIT-1');
    });

    test('a response OMITTING them does not blank stored values', () async {
      // A lean update response (custom controller, `frappe.client.set_value`)
      // may echo only `name` + `modified`. An omitted key must leave the
      // column alone rather than erasing what a pull already persisted.
      await db.update(
        'docs__sales_order',
        {
          'owner': 'alice@example.com',
          'creation': '2026-01-31 09:00:00',
          'modified_by': 'alice@example.com',
        },
        where: 'mobile_uuid = ?',
        whereArgs: ['u-so'],
      );

      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      await ResponseWriteback.apply(
        db: db,
        row: outboxRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {},
        response: const {'name': 'SO-1001', 'modified': '2026-02-02 11:00:00'},
      );

      final p = (await db.query('docs__sales_order')).first;
      expect(p['owner'], 'alice@example.com');
      expect(p['creation'], '2026-01-31 09:00:00');
      expect(p['modified_by'], 'alice@example.com');
      // Everything the response DID carry still lands.
      expect(p['server_name'], 'SO-1001');
      expect(p['modified'], '2026-02-02 11:00:00');
      expect(p['sync_status'], 'synced');
    });

    test('an empty-string value is treated as absent, not written', () async {
      await db.update(
        'docs__sales_order',
        {'owner': 'alice@example.com'},
        where: 'mobile_uuid = ?',
        whereArgs: ['u-so'],
      );

      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      await ResponseWriteback.apply(
        db: db,
        row: outboxRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {},
        response: const {
          'name': 'SO-1001',
          'modified': '2026-02-02 11:00:00',
          'owner': '',
          'creation': null,
        },
      );

      final p = (await db.query('docs__sales_order')).first;
      expect(p['owner'], 'alice@example.com');
      expect(p['creation'], isNull);
    });

    test('omitted on an all-NULL row leaves NULL and does not throw', () async {
      final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
      await ResponseWriteback.apply(
        db: db,
        row: outboxRow,
        parentTable: 'docs__sales_order',
        childTablesByFieldname: const {},
        response: const {'name': 'SO-1001', 'modified': '2026-02-01'},
      );

      final p = (await db.query('docs__sales_order')).first;
      expect(p['owner'], isNull);
      expect(p['creation'], isNull);
      expect(p['modified_by'], isNull);
      expect(p['server_name'], 'SO-1001');
      expect(p['sync_status'], 'synced');
    });

    test(
      'audit fields are written even when more outbox work is queued',
      () async {
        // `hasMore` keeps `sync_status = 'dirty'`, but the server still owns
        // these three — a queued local edit cannot change them.
        final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
        await outbox.insertPending(
          doctype: 'Sales Order',
          mobileUuid: 'u-so',
          operation: OutboxOperation.update,
        );
        await ResponseWriteback.apply(
          db: db,
          row: outboxRow,
          parentTable: 'docs__sales_order',
          childTablesByFieldname: const {},
          response: const {
            'name': 'SO-1001',
            'modified': '2026-02-01',
            'owner': 'alice@example.com',
          },
        );
        final p = (await db.query('docs__sales_order')).first;
        expect(p['sync_status'], 'dirty');
        expect(p['owner'], 'alice@example.com');
      },
    );

    test(
      'a parent table WITHOUT the audit columns does not break the writeback',
      () async {
        // A mirror provisioned outside `buildParentSchemaDDL` /
        // `_migrateV5ToV6` / `reconcileParentTableForMeta` — i.e. exactly the
        // pre-change column set. An unguarded UPDATE would raise `no such
        // column: owner`, roll back the whole writeback and leave the outbox
        // row to re-push a doc the server already accepted.
        await db.execute('''
          CREATE TABLE docs__legacy (
            mobile_uuid TEXT PRIMARY KEY,
            server_name TEXT,
            sync_status TEXT NOT NULL DEFAULT 'dirty',
            sync_error TEXT,
            error_code TEXT,
            sync_attempts INTEGER NOT NULL DEFAULT 0,
            last_attempt_at INTEGER,
            sync_op TEXT,
            push_base_payload TEXT,
            docstatus INTEGER NOT NULL DEFAULT 0,
            modified TEXT,
            local_modified INTEGER NOT NULL,
            pulled_at INTEGER
          )
        ''');
        await db.insert('docs__legacy', {
          'mobile_uuid': 'u-legacy',
          'sync_status': 'dirty',
          'local_modified': 1,
        });
        final legacyId = await outbox.insertPending(
          doctype: 'Legacy',
          mobileUuid: 'u-legacy',
          operation: OutboxOperation.insert,
        );
        final legacyRow = (await outbox.findById(legacyId))!;

        await ResponseWriteback.apply(
          db: db,
          row: legacyRow,
          parentTable: 'docs__legacy',
          childTablesByFieldname: const {},
          response: const {
            'name': 'LEG-1',
            'modified': '2026-02-01 10:00:00',
            'owner': 'alice@example.com',
            'creation': '2026-01-31 09:00:00',
            'modified_by': 'bob@example.com',
          },
        );

        // No throw, and the columns that DO exist were still written.
        final p = (await db.query('docs__legacy')).first;
        expect(p['server_name'], 'LEG-1');
        expect(p['modified'], '2026-02-01 10:00:00');
        expect(p['sync_status'], 'synced');
        expect(await outbox.findById(legacyId), isNull);
      },
    );

    test(
      'THE REGRESSION: a pushed offline row becomes visible to owner = <me>',
      () async {
        // 1. Created offline → `owner` NULL (never fabricated locally).
        // 2. Pushed; the server assigns the real owner.
        // 3. Before this fix the writeback dropped it, so the user's own
        //    freshly-synced record was filtered OUT of their own list.
        const me = 'alice@example.com';
        final meta = DocTypeMeta(
          name: 'Sales Order',
          fields: [f('items', 'Table', options: 'SO Item')],
        );
        final pq = FilterParser.toSql(
          meta: meta,
          tableName: 'docs__sales_order',
          filters: [
            ['owner', '=', me],
          ],
          page: 0,
          pageSize: 50,
        );
        // The clause reaches SQL (it used to be silently dropped, which is
        // why the missing writeback went unnoticed).
        expect(pq.sql, contains('owner'));
        expect(pq.params, contains(me));

        // Precondition: locally-created, NULL owner → invisible to the filter.
        expect((await db.query('docs__sales_order')).first['owner'], isNull);
        expect(await db.rawQuery(pq.sql, pq.params), isEmpty);

        final outboxRow = (await outbox.findByState(OutboxState.pending)).first;
        await ResponseWriteback.apply(
          db: db,
          row: outboxRow,
          parentTable: 'docs__sales_order',
          childTablesByFieldname: const {},
          response: const {
            'name': 'SO-1001',
            'modified': '2026-02-01 10:00:00',
            'owner': me,
            'creation': '2026-02-01 10:00:00',
            'modified_by': me,
          },
        );

        final visible = await db.rawQuery(pq.sql, pq.params);
        expect(visible, hasLength(1));
        expect(visible.first['server_name'], 'SO-1001');
        expect(visible.first['sync_status'], 'synced');
      },
    );
  });
}
