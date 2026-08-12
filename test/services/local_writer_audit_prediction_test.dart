// Covers LocalWriter's LOCAL PREDICTION of Frappe's audit trio (`owner`,
// `creation`, `modified_by`) for a document created on this device.
//
// The bug being closed: `FilterParser` now emits real SQL for those columns,
// but a locally-created row left all three NULL — so the creating user's own
// `owner = <me>` list silently omitted the record they had just saved, until
// it synced AND the server value was written back. Offline-first, that reads
// as "my record vanished".
//
// Frappe assigns `owner` to the authenticated user performing the insert, so
// stamping the session user locally is a correct forecast the server later
// confirms (`frappe.model.get_new_doc` does the same on the web client), not
// fabricated attribution. These tests pin: the prediction, the actual filter
// regression, UPDATE preserving the original author/instant, the no-accessor
// backward-compatibility contract, server values winning, the outbound-payload
// strip (a security property), and the child-table path staying untouched.
import 'dart:convert';

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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

/// Frappe's `Datetime` shape: `YYYY-MM-DD HH:MM:SS`. Space separator, no `T`,
/// no timezone designator — anything else breaks lexicographic comparison
/// against a server-supplied value in a LOCAL `creation >= ...` filter.
/// (These values are never sent to Frappe; they are stripped from every
/// outbound payload. The comparison being protected is local SQLite's.)
final _frappeDateTime = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');

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

  Future<DocTypeMeta> metaFn(String dt) async {
    if (dt == 'Order') return parentMeta;
    if (dt == 'Order Item') return childMeta;
    throw StateError('unexpected meta lookup: $dt');
  }

  Future<void> createMirrorTables(DatabaseExecutor db) async {
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
  }

  group('LocalWriter — audit prediction on a device-created doc', () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      await createMirrorTables(db);
    });

    tearDown(() async => db.close());

    test(
      'stamps owner + modified_by = session user and a real creation',
      () async {
        final writer = LocalWriter(
          db,
          metaFn,
          currentUserId: () => 'alice@example.com',
        );

        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': 'u-new', 'title': 'created on the device'},
        );

        final rows = await db.query('docs__order');
        expect(rows, hasLength(1));
        expect(rows.first['owner'], 'alice@example.com');
        expect(rows.first['modified_by'], 'alice@example.com');

        final creation = rows.first['creation'] as String?;
        expect(creation, isNotNull);
        expect(
          creation,
          matches(_frappeDateTime),
          reason:
              'creation is compared/ordered against server values as TEXT, so it '
              'must use Frappe\'s space-separated format',
        );
        // Sanity: it is genuinely "now", not a placeholder constant. The `Z`
        // suffix mirrors how `PullApply` reads a naive server timestamp.
        final parsed = DateTime.parse('${creation}Z');
        expect(
          DateTime.now().toUtc().difference(parsed).abs(),
          lessThan(const Duration(minutes: 5)),
        );
      },
    );

    test(
      'with NO accessor injected all three stay NULL (back-compat)',
      () async {
        // Every existing construction site — host apps, `FrappeSDK.forTesting`,
        // the whole test suite — passes no accessor. Behaviour there must be
        // byte-identical to before the prediction existed.
        final writer = LocalWriter(db, metaFn);

        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': 'u-plain', 'title': 'no session user'},
        );

        final rows = await db.query('docs__order');
        expect(rows, hasLength(1));
        for (final col in serverAuditColumnNames) {
          expect(rows.first[col], isNull, reason: '$col must stay NULL');
        }
      },
    );

    test('an accessor returning null or blank predicts nothing', () async {
      for (final entry in {'u-null': null, 'u-blank': '   '}.entries) {
        final writer = LocalWriter(
          db,
          metaFn,
          currentUserId: () => entry.value,
        );
        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': entry.key, 'title': 'logged out'},
        );
        final rows = await db.query(
          'docs__order',
          where: 'mobile_uuid = ?',
          whereArgs: [entry.key],
        );
        for (final col in serverAuditColumnNames) {
          expect(rows.first[col], isNull, reason: '$col for ${entry.key}');
        }
      }
    });

    test('a server-supplied value in data wins over the prediction', () async {
      final writer = LocalWriter(
        db,
        metaFn,
        currentUserId: () => 'alice@example.com',
      );

      await writer.writeParent(
        parentDoctype: 'Order',
        data: {
          'mobile_uuid': 'u-server',
          'title': 'from the server',
          'owner': 'zoe@example.com',
          'creation': '2020-01-01 00:00:00',
          'modified_by': 'yan@example.com',
        },
      );

      final rows = await db.query('docs__order');
      expect(rows.first['owner'], 'zoe@example.com');
      expect(rows.first['creation'], '2020-01-01 00:00:00');
      expect(rows.first['modified_by'], 'yan@example.com');
    });

    test(
      're-writing keeps the original owner + creation, moves modified_by',
      () async {
        // The insert is ConflictAlgorithm.replace, so an omitted column is reset
        // to NULL. The writer reads the prior row inside the txn precisely so an
        // edit cannot rewrite authorship.
        await db.insert('docs__order', {
          'mobile_uuid': 'u-edit',
          'sync_status': 'dirty',
          'local_modified': 1,
          'title': 'first save',
          'owner': 'alice@example.com',
          'creation': '2026-01-01 08:00:00',
          'modified_by': 'alice@example.com',
        });

        final writer = LocalWriter(
          db,
          metaFn,
          currentUserId: () => 'bob@example.com',
        );
        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': 'u-edit', 'title': 'second save'},
        );

        final rows = await db.query('docs__order');
        expect(rows, hasLength(1));
        expect(rows.first['title'], 'second save');
        expect(rows.first['owner'], 'alice@example.com');
        expect(rows.first['creation'], '2026-01-01 08:00:00');
        expect(rows.first['modified_by'], 'bob@example.com');
      },
    );

    test('never invents owner for a SERVER-KNOWN row', () async {
      // A pulled doc belongs to whoever created it on the server. Editing it
      // offline must not reassign it to the local user.
      await db.insert('docs__order', {
        'mobile_uuid': 'u-pulled',
        'server_name': 'ORDER-1',
        'sync_status': 'synced',
        'local_modified': 1,
        'title': 'pulled, audit fields absent from the list payload',
      });

      final writer = LocalWriter(
        db,
        metaFn,
        currentUserId: () => 'bob@example.com',
      );
      await writer.writeParent(
        parentDoctype: 'Order',
        serverName: 'ORDER-1',
        data: {'mobile_uuid': 'u-pulled', 'title': 'edited offline'},
      );

      final rows = await db.query('docs__order');
      expect(rows.first['owner'], isNull);
      expect(rows.first['creation'], isNull);
      // The local user IS the one modifying it, so this one does move.
      expect(rows.first['modified_by'], 'bob@example.com');
    });

    test(
      'server-known guard also reads server_name off the DISK row',
      () async {
        // Same as above but the caller OMITS `serverName` — the only public
        // entry point (`writeParent`) makes that easy to do. The guard must
        // still recognise the row as server-known from the on-disk value, or a
        // pulled doc would be reassigned to the local user.
        await db.insert('docs__order', {
          'mobile_uuid': 'u-pulled-2',
          'server_name': 'ORDER-2',
          'sync_status': 'synced',
          'local_modified': 1,
          'title': 'pulled',
        });

        final writer = LocalWriter(
          db,
          metaFn,
          currentUserId: () => 'bob@example.com',
        );
        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': 'u-pulled-2', 'title': 'edited offline'},
        );

        final rows = await db.query(
          'docs__order',
          where: 'mobile_uuid = ?',
          whereArgs: ['u-pulled-2'],
        );
        expect(rows.first['owner'], isNull);
        expect(rows.first['creation'], isNull);
        expect(rows.first['modified_by'], 'bob@example.com');
      },
    );

    test('child rows are unaffected — they carry no audit columns', () async {
      final childCols = (await db.rawQuery(
        'PRAGMA table_info("docs__order_item")',
      )).map((r) => r['name'] as String?).toSet();
      for (final col in serverAuditColumnNames) {
        expect(
          childCols.contains(col),
          isFalse,
          reason: 'child_schema.dart must not emit $col',
        );
      }

      final writer = LocalWriter(
        db,
        metaFn,
        currentUserId: () => 'alice@example.com',
      );

      // Writing audit columns on a child row would be `no such column`.
      await expectLater(
        writer.writeParent(
          parentDoctype: 'Order',
          data: {
            'mobile_uuid': 'u-kids',
            'title': 'with children',
            'items': [
              {'item_name': 'widget', 'qty': 2},
              {'item_name': 'gadget', 'qty': 1},
            ],
          },
        ),
        completes,
      );

      final children = await db.query('docs__order_item', orderBy: 'idx ASC');
      expect(children, hasLength(2));
      expect(children[0]['item_name'], 'widget');
      expect(children[0]['parent_uuid'], 'u-kids');
      expect(children[1]['item_name'], 'gadget');
      // The parent still got its prediction.
      final parent = await db.query('docs__order');
      expect(parent.first['owner'], 'alice@example.com');
    });
  });

  group('the regression: my own offline doc appears in my own list', () {
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
      await createMirrorTables(db);
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
      'owner = <me> returns a doc created offline BEFORE any sync',
      () async {
        final writer = LocalWriter(
          db,
          metaFn,
          currentUserId: () => 'alice@example.com',
        );
        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': 'u-mine', 'title': 'saved offline just now'},
        );

        // Never synced: no server_name, still dirty.
        final raw = await db.query('docs__order');
        expect(raw.first['server_name'], isNull);
        expect(raw.first['sync_status'], 'dirty');

        final result = await makeResolver().resolve(
          doctype: 'Order',
          filters: [
            ['owner', '=', 'alice@example.com'],
          ],
        );

        // Before the prediction, `owner` was NULL here and this list came back
        // EMPTY — the user's own brand-new record looked lost.
        expect(result.rows, hasLength(1));
        expect(result.rows.first['title'], 'saved offline just now');
      },
    );

    test(
      'negative control: without the accessor the same doc is INVISIBLE',
      () async {
        // This is exactly the old behaviour, pinned so the test above cannot
        // silently start passing for the wrong reason: with `owner` NULL the
        // creator's own list comes back empty.
        final writer = LocalWriter(db, metaFn);
        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': 'u-mine', 'title': 'saved offline just now'},
        );

        final result = await makeResolver().resolve(
          doctype: 'Order',
          filters: [
            ['owner', '=', 'alice@example.com'],
          ],
        );
        expect(result.rows, isEmpty);
      },
    );

    test('another user\'s list still does NOT show it', () async {
      final writer = LocalWriter(
        db,
        metaFn,
        currentUserId: () => 'alice@example.com',
      );
      await writer.writeParent(
        parentDoctype: 'Order',
        data: {'mobile_uuid': 'u-mine', 'title': 'alice\'s draft'},
      );

      final result = await makeResolver().resolve(
        doctype: 'Order',
        filters: [
          ['owner', '=', 'bob@example.com'],
        ],
      );
      expect(result.rows, isEmpty);
    });

    test(
      'creation is comparable with a server-formatted range filter',
      () async {
        final writer = LocalWriter(
          db,
          metaFn,
          currentUserId: () => 'alice@example.com',
        );
        await writer.writeParent(
          parentDoctype: 'Order',
          data: {'mobile_uuid': 'u-now', 'title': 'today'},
        );

        final result = await makeResolver().resolve(
          doctype: 'Order',
          filters: [
            ['creation', '>=', '2020-01-01 00:00:00'],
          ],
        );
        expect(
          result.rows,
          hasLength(1),
          reason:
              'a locally-stamped creation must sort correctly against a '
              'server-shaped bound',
        );
      },
    );
  });

  group('OfflineRepository.saveDocument — insert then edit', () {
    late AppDatabase appDb;
    late String sessionUser;
    late OfflineRepository repo;

    setUp(() async {
      appDb = await AppDatabase.inMemoryDatabase();
      addTearDown(appDb.rawDatabase.close);
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Order',
        jsonEncode(parentMeta.toJson()),
      );
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Order Item',
        jsonEncode(childMeta.toJson()),
      );
      await createMirrorTables(appDb.rawDatabase);

      sessionUser = 'alice@example.com';
      final writer = LocalWriter(
        appDb.rawDatabase,
        metaFn,
        currentUserId: () => sessionUser,
      );
      repo = OfflineRepository(appDb, localWriter: writer);
    });

    test('an edit preserves owner + creation but moves modified_by', () async {
      await repo.saveDocument(
        doctype: 'Order',
        data: {'mobile_uuid': 'u-1', 'title': 'created by alice'},
      );

      var rows = await appDb.rawDatabase.query('docs__order');
      expect(rows, hasLength(1));
      expect(rows.first['owner'], 'alice@example.com');
      expect(rows.first['modified_by'], 'alice@example.com');
      final creation = rows.first['creation'] as String?;
      expect(creation, matches(_frappeDateTime));

      // A different user edits the same local row.
      sessionUser = 'bob@example.com';
      await repo.saveDocument(
        doctype: 'Order',
        data: {'mobile_uuid': 'u-1', 'title': 'edited by bob'},
      );

      rows = await appDb.rawDatabase.query('docs__order');
      expect(rows, hasLength(1));
      expect(rows.first['title'], 'edited by bob');
      expect(
        rows.first['owner'],
        'alice@example.com',
        reason: 'authorship belongs to the original creator',
      );
      expect(
        rows.first['creation'],
        creation,
        reason: 'the creation instant never moves',
      );
      expect(
        rows.first['modified_by'],
        'bob@example.com',
        reason: 'the current session user made this edit',
      );
    });

    test('the three are stripped from the outbound payload', () async {
      await repo.saveDocument(
        doctype: 'Order',
        data: {'mobile_uuid': 'u-1', 'title': 'created offline'},
      );
      // Precondition: the row really does carry a predicted owner now, so the
      // strip below is exercised against real values rather than NULLs.
      final rows = await appDb.rawDatabase.query('docs__order');
      expect(rows.first['owner'], 'alice@example.com');

      final payload = await PayloadAssembler.assemble(
        db: appDb.rawDatabase,
        row: OutboxRow(
          id: 1,
          doctype: 'Order',
          mobileUuid: 'u-1',
          operation: OutboxOperation.insert,
          state: OutboxState.pending,
          retryCount: 0,
          createdAt: DateTime.now().toUtc(),
        ),
        parentMeta: parentMeta,
        parentTable: 'docs__order',
        childMetasByFieldname: const {},
        resolveServerName: (_, _) async => null,
      );

      // A client that could send `owner` would forge document attribution —
      // `owner` drives Frappe's permission checks. The local value is a
      // PREDICTION for offline reads only and must never reach the wire.
      for (final col in serverAuditColumnNames) {
        expect(
          payload.containsKey(col),
          isFalse,
          reason: '$col must never be sent to Frappe',
        );
      }
      expect(payload['title'], 'created offline');
    });
  });
}
