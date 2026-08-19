// Covers the materialization of Frappe's server-owned audit fields
// (`owner`, `creation`, `modified_by`) on parent `docs__<doctype>` tables.
//
// Before they were materialized, `FilterParser` silently DROPPED any filter
// clause referencing them. Dropping an AND clause makes the offline result a
// SUPERSET of the server query — an `owner = <current user>` filter became a
// no-op offline and surfaced rows belonging to other users. These tests pin
// the full chain: DDL, both migration paths, the pull writer, the outbound
// payload strip, local-save preservation, and the actual offline filter.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_columns.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/sync/payload_assembler.dart';
import 'package:frappe_mobile_sdk/src/sync/payload_serializer.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// Columns of [table] mapped to their declared SQLite type.
Future<Map<String, String>> _columns(DatabaseExecutor db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info("$table")');
  return {for (final r in info) r['name'] as String: r['type'] as String};
}

/// `notnull` flag per column — the audit columns must all be nullable.
Future<Map<String, int>> _notNullFlags(
  DatabaseExecutor db,
  String table,
) async {
  final info = await db.rawQuery('PRAGMA table_info("$table")');
  return {for (final r in info) r['name'] as String: r['notnull'] as int};
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final parentMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('customer', 'Link', options: 'Customer'),
      f('items', 'Table', options: 'Order Item'),
    ],
  );
  final childMeta = DocTypeMeta(
    name: 'Order Item',
    isTable: true,
    fields: [f('item_name', 'Data'), f('qty', 'Int')],
  );

  group('schema', () {
    test('parent DDL emits all three as NULLABLE TEXT', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      for (final s in buildParentSchemaDDL(
        parentMeta,
        tableName: 'docs__order',
      )) {
        await db.execute(s);
      }

      final cols = await _columns(db, 'docs__order');
      final notNull = await _notNullFlags(db, 'docs__order');
      for (final col in serverAuditColumnNames) {
        expect(cols[col], 'TEXT', reason: '$col must be TEXT');
        expect(
          notNull[col],
          0,
          reason: '$col must be nullable — existing rows have no value',
        );
      }
    });

    test('child DDL does NOT emit them (parent-only scope)', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      for (final s in buildChildSchemaDDL(
        childMeta,
        tableName: 'docs__order_item',
      )) {
        await db.execute(s);
      }

      final cols = await _columns(db, 'docs__order_item');
      for (final col in serverAuditColumnNames) {
        expect(
          cols.containsKey(col),
          isFalse,
          reason:
              '$col is deliberately parent-only; widening to children would '
              'multiply blast radius for no known consumer',
        );
      }
    });

    test('the three are in the parent + sync-metadata column sets', () {
      // Parent set → the meta loop drops a same-named DocField instead of
      // emitting a duplicate column (SQLite rejects those in CREATE TABLE).
      expect(systemParentColumnNames, containsAll(serverAuditColumnNames));
      // Sync-metadata set → stripped from outbound payloads AND from the
      // ThreeWayMerge base, so the two cannot disagree.
      expect(
        systemSyncMetadataColumnNames,
        containsAll(serverAuditColumnNames),
      );
      // Child set must stay clear of them.
      for (final col in serverAuditColumnNames) {
        expect(systemChildColumnNames, isNot(contains(col)));
      }
    });
  });

  group('migration — existing installs', () {
    test(
      'reconcileParentTableForMeta adds them to an OLD table that lacks them',
      () async {
        final appDb = await AppDatabase.inMemoryDatabase();
        addTearDown(appDb.rawDatabase.close);

        // A `docs__order` table exactly as a pre-change SDK build created it:
        // every system column EXCEPT the three audit ones, plus meta fields.
        await appDb.rawDatabase.execute('''
          CREATE TABLE docs__order (
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
            pulled_at INTEGER,
            title TEXT,
            title__norm TEXT,
            customer TEXT,
            customer__is_local INTEGER
          )
        ''');
        // A pre-existing row must survive the ALTER untouched.
        await appDb.rawDatabase.insert('docs__order', {
          'mobile_uuid': 'legacy-1',
          'sync_status': 'synced',
          'local_modified': 1,
          'title': 'legacy row',
        });

        final before = await _columns(appDb.rawDatabase, 'docs__order');
        for (final col in serverAuditColumnNames) {
          expect(
            before.containsKey(col),
            isFalse,
            reason: 'precondition: the OLD table must lack $col',
          );
        }

        final repo = OfflineRepository(appDb);
        await repo.reconcileParentTableForMeta(
          'Order',
          'docs__order',
          parentMeta,
        );

        final after = await _columns(appDb.rawDatabase, 'docs__order');
        final notNull = await _notNullFlags(appDb.rawDatabase, 'docs__order');
        for (final col in serverAuditColumnNames) {
          expect(after[col], 'TEXT', reason: '$col must be added as TEXT');
          expect(notNull[col], 0, reason: '$col must be added nullable');
        }

        // The reconcile only ADDS columns — the existing row is intact and
        // its new columns read back NULL (never invented locally).
        final rows = await appDb.rawDatabase.query('docs__order');
        expect(rows, hasLength(1));
        expect(rows.first['title'], 'legacy row');
        for (final col in serverAuditColumnNames) {
          expect(rows.first[col], isNull);
        }
        final idx = await appDb.rawDatabase.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='docs__order'",
        );
        expect(
          idx.map((r) => r['name']),
          contains('ix_order_owner'),
          reason:
              'a table that gains `owner` via reconcile must gain its '
              'index too',
        );

        // Idempotent: a second reconcile must not throw "duplicate column".
        await repo.reconcileParentTableForMeta(
          'Order',
          'docs__order',
          parentMeta,
        );
        expect(
          (await _columns(appDb.rawDatabase, 'docs__order')).keys,
          containsAll(serverAuditColumnNames),
        );
        final idxAgain = await appDb.rawDatabase.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='docs__order'",
        );
        expect(
          idxAgain.map((r) => r['name']),
          contains('ix_order_owner'),
          reason:
              'the second pass is a DIFFERENT code path from the first: the '
              'first indexed post-ALTER inside the `try`, the second takes the '
              '`addedFields.isEmpty` early return guarded by '
              '`actual.contains(\'owner\')` — and must neither throw nor drop '
              'the index',
        );
      },
    );

    test(
      'reconcile indexes owner on a table that already HAS the audit columns',
      () async {
        final appDb = await AppDatabase.inMemoryDatabase();
        addTearDown(appDb.rawDatabase.close);

        // A host that provisioned its own table WITH the audit columns but
        // WITHOUT the index: the reconcile has nothing to add, so its very
        // first call takes the early return — which must still index `owner`.
        await appDb.rawDatabase.execute('''
          CREATE TABLE docs__order (
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
            pulled_at INTEGER,
            owner TEXT,
            creation TEXT,
            modified_by TEXT,
            title TEXT,
            title__norm TEXT,
            customer TEXT,
            customer__is_local INTEGER
          )
        ''');

        final before = await appDb.rawDatabase.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='docs__order'",
        );
        expect(
          before.map((r) => r['name']),
          isNot(contains('ix_order_owner')),
          reason: 'precondition: the host-provisioned table has no owner index',
        );

        final repo = OfflineRepository(appDb);
        await repo.reconcileParentTableForMeta(
          'Order',
          'docs__order',
          parentMeta,
        );

        final after = await appDb.rawDatabase.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='docs__order'",
        );
        expect(
          after.map((r) => r['name']),
          contains('ix_order_owner'),
          reason:
              'the index call is deliberately NOT gated on "we just added '
              '`owner`" — a table provisioned with the columns and without the '
              'index keeps the full scan the index exists to remove',
        );
      },
    );

    test(
      'v5 → v6 backfills them on every existing docs__ PARENT table',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('audit_cols_v5_v6_');
        addTearDown(() {
          if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
        });
        final dbPath = p.join(tmpDir.path, 'test.db');

        // A v5 device: docs__ tables exist without the audit columns. Only
        // `sdk_meta` + the mirrors matter for this migration step.
        final v5db = await openDatabase(
          dbPath,
          version: 5,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE sdk_meta (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              schema_version INTEGER NOT NULL DEFAULT 0,
              session_user_json TEXT,
              bootstrap_done INTEGER NOT NULL DEFAULT 0,
              offline_enabled INTEGER NOT NULL DEFAULT 0,
              offline_enabled_set_at INTEGER
            )
          ''');
            await db.insert('sdk_meta', {'id': 1, 'schema_version': 5});
            // Parent mirror — identified by the presence of `sync_status`.
            await db.execute(
              'CREATE TABLE docs__order ('
              '  mobile_uuid TEXT PRIMARY KEY,'
              '  server_name TEXT,'
              '  sync_status TEXT,'
              '  local_modified INTEGER,'
              '  title TEXT'
              ')',
            );
            await db.insert('docs__order', {
              'mobile_uuid': 'legacy-1',
              'sync_status': 'synced',
              'local_modified': 1,
              'title': 'legacy row',
            });
            // Child mirror — no `sync_status`; must be left alone.
            await db.execute(
              'CREATE TABLE docs__order_item ('
              '  mobile_uuid TEXT PRIMARY KEY,'
              '  parent_uuid TEXT,'
              '  parentfield TEXT,'
              '  idx INTEGER'
              ')',
            );
          },
          singleInstance: false,
        );
        expect(
          (await _columns(v5db, 'docs__order')).containsKey('owner'),
          isFalse,
          reason: 'precondition: v5 parent mirror has no owner column',
        );
        await v5db.close();

        AppDatabaseTestSeam.resetSingleton();
        final v6db = await openDatabase(
          dbPath,
          version: 6,
          onConfigure: AppDatabaseTestSeam.runOnConfigure,
          onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
          singleInstance: false,
        );
        addTearDown(v6db.close);

        final parentCols = await _columns(v6db, 'docs__order');
        final parentNotNull = await _notNullFlags(v6db, 'docs__order');
        for (final col in serverAuditColumnNames) {
          expect(parentCols[col], 'TEXT', reason: '$col must be added as TEXT');
          expect(parentNotNull[col], 0, reason: '$col must be added nullable');
        }

        // Child mirrors keep the shape `child_schema.dart` emits, so an
        // upgraded install does not drift from a fresh one.
        final childCols = await _columns(v6db, 'docs__order_item');
        for (final col in serverAuditColumnNames) {
          expect(
            childCols.containsKey(col),
            isFalse,
            reason: 'child mirror must be skipped',
          );
        }

        // Existing data preserved; new columns read back NULL.
        final rows = await v6db.query('docs__order');
        expect(rows, hasLength(1));
        expect(rows.first['title'], 'legacy row');
        expect(rows.first['owner'], isNull);

        final meta = await v6db.query('sdk_meta', where: 'id = 1');
        expect(meta.first['schema_version'], 7);
      },
    );

    test(
      'v5 → v6 is idempotent (re-run after an interrupted upgrade)',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('audit_cols_idem_');
        addTearDown(() {
          if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
        });
        final dbPath = p.join(tmpDir.path, 'test.db');

        final db = await openDatabase(
          dbPath,
          version: 5,
          onCreate: (d, _) async {
            await d.execute('''
            CREATE TABLE sdk_meta (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              schema_version INTEGER NOT NULL DEFAULT 0,
              session_user_json TEXT,
              bootstrap_done INTEGER NOT NULL DEFAULT 0,
              offline_enabled INTEGER NOT NULL DEFAULT 0,
              offline_enabled_set_at INTEGER
            )
          ''');
            await d.insert('sdk_meta', {'id': 1, 'schema_version': 5});
            // Already half-migrated: `owner` present, the other two absent.
            await d.execute(
              'CREATE TABLE docs__order ('
              '  mobile_uuid TEXT PRIMARY KEY,'
              '  sync_status TEXT,'
              '  owner TEXT'
              ')',
            );
          },
          singleInstance: false,
        );
        addTearDown(db.close);

        await AppDatabaseTestSeam.runOnUpgrade(db, 5, 6);
        await AppDatabaseTestSeam.runOnUpgrade(db, 5, 6);

        expect(
          (await _columns(db, 'docs__order')).keys,
          containsAll(serverAuditColumnNames),
        );
      },
    );

    test(
      'v5 → v6 clears every pull cursor so the audit columns get backfilled',
      () async {
        // Adding the columns is not enough. Once a doctype is `complete`, pulls
        // are incremental (`modified >= cursor.modified`), so an upgraded
        // install would only ever receive audit values for rows whose
        // `modified` advanced server-side — every pre-existing row would keep
        // NULL forever, and `IFNULL(owner,'') = <me>` would match none of them.
        // The result is a silently PARTIAL filter, which is harder to notice
        // than the `no such column` throw this migration replaced.
        final tmpDir = Directory.systemTemp.createTempSync(
          'audit_cols_cursor_',
        );
        addTearDown(() {
          if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
        });
        final dbPath = p.join(tmpDir.path, 'test.db');

        final db = await openDatabase(
          dbPath,
          version: 5,
          onCreate: (d, _) async {
            await d.execute('''
            CREATE TABLE sdk_meta (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              schema_version INTEGER NOT NULL DEFAULT 0,
              session_user_json TEXT,
              bootstrap_done INTEGER NOT NULL DEFAULT 0,
              offline_enabled INTEGER NOT NULL DEFAULT 0,
              offline_enabled_set_at INTEGER
            )
          ''');
            await d.insert('sdk_meta', {'id': 1, 'schema_version': 5});
            await d.execute(
              'CREATE TABLE doctype_meta ('
              '  doctype TEXT PRIMARY KEY,'
              '  table_name TEXT,'
              '  last_ok_cursor TEXT,'
              '  last_pull_ok_at INTEGER'
              ')',
            );
            // Two drained doctypes — both would otherwise stay incremental.
            await d.insert('doctype_meta', {
              'doctype': 'Order',
              'table_name': 'docs__order',
              'last_ok_cursor':
                  '{"modified":"2026-01-01 00:00:00","name":"O-1",'
                  '"complete":true}',
              'last_pull_ok_at': 1,
            });
            await d.insert('doctype_meta', {
              'doctype': 'Customer',
              'table_name': 'docs__customer',
              'last_ok_cursor':
                  '{"modified":"2026-02-02 00:00:00","name":"C-9",'
                  '"complete":true}',
              'last_pull_ok_at': 2,
            });
            await d.execute(
              'CREATE TABLE docs__order ('
              '  mobile_uuid TEXT PRIMARY KEY,'
              '  sync_status TEXT'
              ')',
            );
          },
          singleInstance: false,
        );
        addTearDown(db.close);

        await AppDatabaseTestSeam.runOnUpgrade(db, 5, 6);

        final rows = await db.query('doctype_meta', orderBy: 'doctype');
        expect(rows, hasLength(2));
        for (final r in rows) {
          expect(
            r['last_ok_cursor'],
            isNull,
            reason:
                '${r['doctype']} must re-drain on the next sync; a surviving '
                'complete cursor pins it to incremental pulls forever',
          );
        }
        // Everything else about the row is left alone.
        expect(rows.first['doctype'], 'Customer');
        expect(rows.first['table_name'], 'docs__customer');

        // The ALTERs still ran and the version still landed — the cursor clear
        // shares their transaction, so a failure would have rolled both back.
        expect(
          (await _columns(db, 'docs__order')).keys,
          containsAll(serverAuditColumnNames),
        );
        final meta = await db.query('sdk_meta', where: 'id = 1');
        expect(meta.first['schema_version'], 7);
      },
    );

    test('v5 → v6 survives a doctype_meta without last_ok_cursor', () async {
      // `last_ok_cursor` is added on the v2→v3 leg, which `_onUpgrade` always
      // runs first, so production DBs reaching v6 always have it. Guarded
      // anyway: an unexpected throw would roll back the ALTERs and leave the
      // schema unmigrated.
      final tmpDir = Directory.systemTemp.createTempSync('audit_cols_nocur_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });
      final dbPath = p.join(tmpDir.path, 'test.db');

      final db = await openDatabase(
        dbPath,
        version: 5,
        onCreate: (d, _) async {
          await d.execute('''
            CREATE TABLE sdk_meta (
              id INTEGER PRIMARY KEY CHECK (id = 1),
              schema_version INTEGER NOT NULL DEFAULT 0,
              session_user_json TEXT,
              bootstrap_done INTEGER NOT NULL DEFAULT 0,
              offline_enabled INTEGER NOT NULL DEFAULT 0,
              offline_enabled_set_at INTEGER
            )
          ''');
          await d.insert('sdk_meta', {'id': 1, 'schema_version': 5});
          await d.execute(
            'CREATE TABLE doctype_meta (doctype TEXT PRIMARY KEY)',
          );
          await d.insert('doctype_meta', {'doctype': 'Order'});
          await d.execute(
            'CREATE TABLE docs__order ('
            '  mobile_uuid TEXT PRIMARY KEY,'
            '  sync_status TEXT'
            ')',
          );
        },
        singleInstance: false,
      );
      addTearDown(db.close);

      await AppDatabaseTestSeam.runOnUpgrade(db, 5, 6);

      expect(
        (await _columns(db, 'docs__order')).keys,
        containsAll(serverAuditColumnNames),
      );
      final meta = await db.query('sdk_meta', where: 'id = 1');
      expect(meta.first['schema_version'], 7);
    });
  });

  group('pull persists the server values', () {
    test('applyPage writes all three and they read back', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      for (final s in buildParentSchemaDDL(
        parentMeta,
        tableName: 'docs__order',
      )) {
        await db.execute(s);
      }
      for (final s in buildChildSchemaDDL(
        childMeta,
        tableName: 'docs__order_item',
      )) {
        await db.execute(s);
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          doctype TEXT NOT NULL,
          mobile_uuid TEXT NOT NULL,
          operation TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'pending',
          error_code TEXT,
          error_message TEXT,
          payload TEXT,
          created_at INTEGER NOT NULL
        )
      ''');

      await PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__order',
        childMetasByFieldname: const {},
        rows: [
          {
            'name': 'ORDER-1',
            'title': 'from server',
            'modified': '2026-07-01 10:00:00',
            'owner': 'alice@example.com',
            'creation': '2026-06-01 09:00:00',
            'modified_by': 'bob@example.com',
          },
        ],
      );

      final rows = await db.query('docs__order');
      expect(rows, hasLength(1));
      expect(rows.first['owner'], 'alice@example.com');
      expect(rows.first['creation'], '2026-06-01 09:00:00');
      expect(rows.first['modified_by'], 'bob@example.com');
    });

    test('a page omitting them does not blank values already stored', () async {
      // The sequential path UPDATEs; an omitted key must leave the column
      // untouched rather than resetting it to NULL.
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      for (final s in buildParentSchemaDDL(
        parentMeta,
        tableName: 'docs__order',
      )) {
        await db.execute(s);
      }
      await db.execute('''
        CREATE TABLE IF NOT EXISTS outbox (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          doctype TEXT NOT NULL,
          mobile_uuid TEXT NOT NULL,
          operation TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'pending',
          error_code TEXT,
          error_message TEXT,
          payload TEXT,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.insert('docs__order', {
        'mobile_uuid': 'u-1',
        'server_name': 'ORDER-1',
        'sync_status': 'synced',
        'local_modified': 1,
        'owner': 'alice@example.com',
      });

      await PullApply.applyPage(
        db: db,
        parentMeta: parentMeta,
        parentTable: 'docs__order',
        childMetasByFieldname: const {},
        rows: [
          {
            'name': 'ORDER-1',
            'title': 'edited on server',
            'modified': '2026-07-02 10:00:00',
          },
        ],
      );

      final rows = await db.query('docs__order');
      expect(rows, hasLength(1));
      expect(rows.first['title'], 'edited on server');
      expect(rows.first['owner'], 'alice@example.com');
    });
  });

  group('outbound payload safety', () {
    test('assembled payload strips all three (never sent to Frappe)', () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(db.close);
      for (final s in buildParentSchemaDDL(
        parentMeta,
        tableName: 'docs__order',
      )) {
        await db.execute(s);
      }
      await db.insert('docs__order', {
        'mobile_uuid': 'u-1',
        'server_name': 'ORDER-1',
        'sync_status': 'dirty',
        'local_modified': 1,
        'title': 'edited locally',
        'owner': 'alice@example.com',
        'creation': '2026-06-01 09:00:00',
        'modified_by': 'bob@example.com',
      });

      final payload = await PayloadAssembler.assemble(
        db: db,
        row: OutboxRow(
          id: 1,
          doctype: 'Order',
          mobileUuid: 'u-1',
          operation: OutboxOperation.update,
          state: OutboxState.pending,
          retryCount: 0,
          createdAt: DateTime.now().toUtc(),
        ),
        parentMeta: parentMeta,
        parentTable: 'docs__order',
        childMetasByFieldname: const {},
        resolveServerName: (_, _) async => null,
      );

      // Frappe owns these fields. A client that sent `owner` could forge
      // document attribution, so they must never reach the wire.
      for (final col in serverAuditColumnNames) {
        expect(
          payload.containsKey(col),
          isFalse,
          reason: '$col must be stripped from the outbound payload',
        );
      }
      // The user's actual edit still goes out.
      expect(payload['title'], 'edited locally');
    });

    test('ThreeWayMerge base snapshot strips the same three', () {
      // PayloadAssembler and PayloadSerializer must agree — if the base
      // snapshot and the outbound payload disagreed about these fields the
      // merge would see phantom diffs.
      final base = PayloadSerializer.serializeForBase({
        'mobile_uuid': 'u-1',
        'server_name': 'ORDER-1',
        'title': 'edited locally',
        'modified': '2026-07-01 10:00:00',
        'owner': 'alice@example.com',
        'creation': '2026-06-01 09:00:00',
        'modified_by': 'bob@example.com',
      }, parentMeta);

      for (final col in serverAuditColumnNames) {
        expect(base.containsKey(col), isFalse, reason: '$col must be stripped');
      }
      // `modified` is still a genuine Frappe field on the wire.
      expect(base['modified'], '2026-07-01 10:00:00');
      expect(base['title'], 'edited locally');
    });
  });

  group('offline filter behaviour', () {
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
          sortOrder INTEGER,
          table_name TEXT
        )
      ''');
      for (final s in buildParentSchemaDDL(
        parentMeta,
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
      metaDao = DoctypeMetaDao(db);
    });

    tearDown(() async => db.close());

    UnifiedResolver makeResolver() => UnifiedResolver(
      db: db,
      metaDao: metaDao,
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: (_) async => parentMeta,
    );

    test(
      'owner = A returns ONLY A\'s row — the bug this change fixes',
      () async {
        await db.insert('docs__order', {
          'mobile_uuid': 'u-a',
          'server_name': 'ORDER-A',
          'sync_status': 'synced',
          'local_modified': 1,
          'title': 'belongs to alice',
          'owner': 'alice@example.com',
        });
        await db.insert('docs__order', {
          'mobile_uuid': 'u-b',
          'server_name': 'ORDER-B',
          'sync_status': 'synced',
          'local_modified': 1,
          'title': 'belongs to bob',
          'owner': 'bob@example.com',
        });

        final result = await makeResolver().resolve(
          doctype: 'Order',
          filters: [
            ['owner', '=', 'alice@example.com'],
          ],
        );

        // Previously the clause was dropped, so BOTH rows came back and a
        // user could see a record that was not theirs.
        expect(result.rows, hasLength(1));
        expect(result.rows.first['title'], 'belongs to alice');
      },
    );

    test('a row with NULL owner is excluded from owner = A', () async {
      // A locally-created doc has no server-assigned owner yet. It must not
      // leak into another user's filtered list.
      await db.insert('docs__order', {
        'mobile_uuid': 'u-local',
        'sync_status': 'dirty',
        'local_modified': 1,
        'title': 'created offline, owner unknown',
      });
      await db.insert('docs__order', {
        'mobile_uuid': 'u-a',
        'server_name': 'ORDER-A',
        'sync_status': 'synced',
        'local_modified': 1,
        'title': 'belongs to alice',
        'owner': 'alice@example.com',
      });

      final result = await makeResolver().resolve(
        doctype: 'Order',
        filters: [
          ['owner', '=', 'alice@example.com'],
        ],
      );
      expect(result.rows, hasLength(1));
      expect(result.rows.first['mobile_uuid'], 'u-a');
    });

    test('creation range filter runs as real SQL', () async {
      await db.insert('docs__order', {
        'mobile_uuid': 'u-old',
        'sync_status': 'synced',
        'local_modified': 1,
        'creation': '2025-01-01 00:00:00',
      });
      await db.insert('docs__order', {
        'mobile_uuid': 'u-new',
        'sync_status': 'synced',
        'local_modified': 1,
        'creation': '2026-06-01 00:00:00',
      });

      final result = await makeResolver().resolve(
        doctype: 'Order',
        filters: [
          ['creation', '>=', '2026-01-01 00:00:00'],
        ],
      );
      expect(result.rows, hasLength(1));
      expect(result.rows.first['mobile_uuid'], 'u-new');
    });
  });

  group('local save', () {
    test(
      'editing a pulled doc preserves owner instead of blanking it',
      () async {
        // LocalWriter inserts with ConflictAlgorithm.replace, so any column
        // it does not emit is reset to NULL. Without preservation an edit
        // would erase `owner` and drop the row out of an `owner = <me>` list.
        final appDb = await AppDatabase.inMemoryDatabase();
        addTearDown(appDb.rawDatabase.close);

        await appDb.doctypeMetaDao.upsertMetaJson(
          'Order',
          jsonEncode(parentMeta.toJson()),
        );
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Order Item',
          jsonEncode(childMeta.toJson()),
        );
        for (final s in buildParentSchemaDDL(
          parentMeta,
          tableName: 'docs__order',
        )) {
          await appDb.rawDatabase.execute(s);
        }
        for (final s in buildChildSchemaDDL(
          childMeta,
          tableName: 'docs__order_item',
        )) {
          await appDb.rawDatabase.execute(s);
        }

        // A previously-pulled, server-known row.
        await appDb.rawDatabase.insert('docs__order', {
          'mobile_uuid': 'u-1',
          'server_name': 'ORDER-1',
          'sync_status': 'synced',
          'local_modified': 1,
          'title': 'original',
          'owner': 'alice@example.com',
          'creation': '2026-06-01 09:00:00',
          'modified_by': 'alice@example.com',
        });

        final writer = LocalWriter(appDb.rawDatabase, (dt) async {
          final entity = await appDb.doctypeMetaDao.findByDoctype(dt);
          if (entity == null) throw StateError('no meta for $dt');
          return DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
        });
        final repo = OfflineRepository(appDb, localWriter: writer);

        // The form payload carries no audit fields — as a real form save does.
        await repo.saveDocument(
          doctype: 'Order',
          data: {'mobile_uuid': 'u-1', 'title': 'edited offline'},
        );

        final rows = await appDb.rawDatabase.query('docs__order');
        expect(rows, hasLength(1));
        expect(rows.first['title'], 'edited offline');
        expect(rows.first['owner'], 'alice@example.com');
        expect(rows.first['creation'], '2026-06-01 09:00:00');
        expect(rows.first['modified_by'], 'alice@example.com');
      },
    );

    test('back-compat: with NO currentUserId accessor wired, a locally-created '
        'doc leaves all three NULL (the pre-prediction contract). With an '
        'accessor, LocalWriter stamps a prediction — see '
        'local_writer_audit_prediction_test.dart', () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      addTearDown(appDb.rawDatabase.close);

      await appDb.doctypeMetaDao.upsertMetaJson(
        'Order',
        jsonEncode(parentMeta.toJson()),
      );
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Order Item',
        jsonEncode(childMeta.toJson()),
      );
      for (final s in buildParentSchemaDDL(
        parentMeta,
        tableName: 'docs__order',
      )) {
        await appDb.rawDatabase.execute(s);
      }
      for (final s in buildChildSchemaDDL(
        childMeta,
        tableName: 'docs__order_item',
      )) {
        await appDb.rawDatabase.execute(s);
      }

      final writer = LocalWriter(appDb.rawDatabase, (dt) async {
        final entity = await appDb.doctypeMetaDao.findByDoctype(dt);
        if (entity == null) throw StateError('no meta for $dt');
        return DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
      });
      final repo = OfflineRepository(appDb, localWriter: writer);

      await repo.saveDocument(
        doctype: 'Order',
        data: {'mobile_uuid': 'u-new', 'title': 'brand new'},
      );

      final rows = await appDb.rawDatabase.query('docs__order');
      expect(rows, hasLength(1));
      // Writing the local user into `owner` would fabricate audit data.
      for (final col in serverAuditColumnNames) {
        expect(rows.first[col], isNull, reason: '$col must stay NULL');
      }
    });
  });
}
