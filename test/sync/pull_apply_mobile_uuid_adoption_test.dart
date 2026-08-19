// A pulled row that carries a non-empty `mobile_uuid` must be stored under
// THAT uuid, not under a freshly minted one.
//
// `mobile_uuid` is provisioned server-side as a UNIQUE Data field (by
// `mobile_control`, on parent and child doctypes alike), so a non-empty
// incoming value is a real global identity — the one this device assigned when
// it created the document. Discarding it and minting a new v4 silently breaks
// the round trip: the same server record ends up under a different local
// identity after any wipe (logout, reinstall, fresh device), which defeats the
// `mobile_uuid` fallback match that exists precisely to reconcile a row whose
// `server_name` writeback was interrupted.
//
// An EMPTY or absent incoming uuid must still mint, and that is not an
// oversight: Desk-created rows return `mobile_uuid` as null / '', and
// `mobile_uuid` is the local primary key — adopting '' would write an empty PK
// and the second such row would collide.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:frappe_mobile_sdk/src/utils/uuid_pattern.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DocTypeMeta parentMeta;
  late DocTypeMeta childMeta;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    parentMeta = DocTypeMeta(
      name: 'Sales Order',
      titleField: 'customer',
      fields: [
        f('customer', 'Link', options: 'Customer'),
        f('items', 'Table', options: 'Sales Order Item'),
      ],
    );
    childMeta = DocTypeMeta(
      name: 'Sales Order Item',
      isTable: true,
      fields: [f('item_code', 'Data'), f('qty', 'Int')],
    );
    for (final s in buildParentSchemaDDL(
      parentMeta,
      tableName: 'docs__sales_order',
    )) {
      await db.execute(s);
    }
    for (final s in buildChildSchemaDDL(
      childMeta,
      tableName: 'docs__sales_order_item',
    )) {
      await db.execute(s);
    }
    // The sequential path's isOwnInsertRoundtrip guard queries this table.
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
  });

  tearDown(() async => db.close());

  Future<void> pull(
    List<Map<String, dynamic>> rows, {
    bool isInitialSync = false,
  }) => PullApply.applyPage(
    db: db,
    parentMeta: parentMeta,
    parentTable: 'docs__sales_order',
    childMetasByFieldname: {
      'items': PullApplyChildInfo('Sales Order Item', childMeta),
    },
    rows: rows,
    isInitialSync: isInitialSync,
  );

  const serverUuid = 'c05249e9-af5d-43b5-ad30-a195ce2e7b1d';

  group('parent adopts a non-empty incoming mobile_uuid', () {
    // The post-wipe scenario: initial sync into an empty table takes the
    // BULK path, which is what runs after logout(clearDatabase: true).
    test('on the bulk (initial-sync) path', () async {
      await pull([
        {
          'name': 'SO-1',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-1',
          'mobile_uuid': serverUuid,
          'items': [
            {'item_code': 'A', 'qty': 1},
          ],
        },
      ], isInitialSync: true);

      final p = await db.query('docs__sales_order');
      expect(p.length, 1);
      expect(
        p.first['mobile_uuid'],
        serverUuid,
        reason:
            'the server round-tripped the uuid this device assigned; '
            'minting a new one breaks the identity across a wipe',
      );
    });

    test('on the sequential path', () async {
      await pull([
        {
          'name': 'SO-2',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-2',
          'mobile_uuid': serverUuid,
          'items': const <Map<String, dynamic>>[],
        },
      ]);

      final p = await db.query('docs__sales_order');
      expect(p.length, 1);
      expect(p.first['mobile_uuid'], serverUuid);
    });

    // Child rows carry the parent's LOCAL uuid in parent_uuid. Adopting the
    // parent's incoming uuid must keep that link intact, or the children are
    // orphaned from the row that owns them.
    test('and its children still point at it via parent_uuid', () async {
      await pull([
        {
          'name': 'SO-3',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-3',
          'mobile_uuid': serverUuid,
          'items': [
            {'item_code': 'A', 'qty': 1},
            {'item_code': 'B', 'qty': 2},
          ],
        },
      ], isInitialSync: true);

      final children = await db.query('docs__sales_order_item');
      expect(children.length, 2);
      for (final c in children) {
        expect(
          c['parent_uuid'],
          serverUuid,
          reason: 'children must hang off the adopted parent uuid',
        );
      }
    });
  });

  group('an empty or absent incoming mobile_uuid still mints', () {
    // Regression guards, not new behaviour: adopting '' would write an empty
    // primary key and the next such row would collide. Desk-origin rows are
    // exactly this case.
    test('empty string is not adopted', () async {
      await pull([
        {
          'name': 'SO-4',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-4',
          'mobile_uuid': '',
          'items': const <Map<String, dynamic>>[],
        },
      ], isInitialSync: true);

      final p = await db.query('docs__sales_order');
      expect(p.length, 1);
      expect((p.first['mobile_uuid'] as String?) ?? '', isNotEmpty);
    });

    test(
      'two Desk-origin rows with empty uuids get distinct local ids',
      () async {
        await pull([
          {
            'name': 'SO-5',
            'modified': '2026-01-01 00:00:00',
            'customer': 'CUST-5',
            'mobile_uuid': null,
            'items': const <Map<String, dynamic>>[],
          },
          {
            'name': 'SO-6',
            'modified': '2026-01-01 00:00:00',
            'customer': 'CUST-6',
            'mobile_uuid': '',
            'items': const <Map<String, dynamic>>[],
          },
        ], isInitialSync: true);

        final p = await db.query('docs__sales_order', orderBy: 'server_name');
        expect(p.length, 2, reason: 'neither row may collide on an empty PK');
        expect(p[0]['mobile_uuid'], isNot(p[1]['mobile_uuid']));
      },
    );
  });

  group('a non-UUID-shaped incoming value is not adopted', () {
    // `mobile_uuid` being UUID-shaped is an invariant four places rely on, and
    // `uuid_rewriter.dart` documents the shape check as "the complete detector"
    // for a local Link reference — Frappe server names are never UUID-shaped
    // and SDK uuids always are. Adopting a non-UUID string would put a value
    // into the local primary key that `looksLikeMobileUuid` rejects, so:
    //
    //   * `uuid_rewriter` would fall back to `__is_local` alone, which its own
    //     comment records as insufficient for fetch_from / defaults /
    //     programmatic prefill / back-reference Links;
    //   * `push_engine`'s dependency scan would not see the reference, so the
    //     row would land in its parent's tier and race it.
    //
    // Reachability is low — a link value only carries a `mobile_uuid` when the
    // target row has no `server_name`, and an adopted row always has one — but
    // minting instead costs nothing and keeps the invariant true by
    // construction rather than by argument.
    test('a server-name-shaped uuid mints instead', () async {
      await pull([
        {
          'name': 'SO-9',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-9',
          'mobile_uuid': 'HSFM-2026-00042',
          'items': const <Map<String, dynamic>>[],
        },
      ], isInitialSync: true);

      final p = await db.query('docs__sales_order');
      expect(p.length, 1);
      expect(
        p.first['mobile_uuid'],
        isNot('HSFM-2026-00042'),
        reason: 'a non-UUID value must not become the local primary key',
      );
      expect(
        looksLikeMobileUuid(p.first['mobile_uuid'] as String?),
        isTrue,
        reason: 'the minted fallback must satisfy the shape invariant',
      );
    });

    // Children deliberately do NOT get this gate. Child adoption predates the
    // parent's and is load-bearing: a Link field on another document can
    // reference a child row by its `mobile_uuid`, so a child whose uuid changed
    // on re-pull left that Link a permanent orphan (pinned by
    // `pull_apply_test.dart`'s "child mobile_uuid is preserved across
    // re-pull"). Deployments exist whose child uuids are not v4-shaped.
    test('but a child row still adopts a non-UUID incoming uuid', () async {
      await pull([
        {
          'name': 'SO-10',
          'modified': '2026-01-01 00:00:00',
          'customer': 'CUST-10',
          'mobile_uuid': serverUuid,
          'items': [
            {'item_code': 'A', 'qty': 1, 'mobile_uuid': 'fm-uuid-stable-1234'},
          ],
        },
      ], isInitialSync: true);

      final c = await db.query('docs__sales_order_item');
      expect(c.length, 1);
      expect(
        c.first['mobile_uuid'],
        'fm-uuid-stable-1234',
        reason:
            'gating children on shape would re-break the orphan-Link '
            'regression that child adoption exists to prevent',
      );
    });
  });

  group('an existing local row keeps its own uuid', () {
    // Adoption must never renumber a row that already exists locally — the
    // local uuid is referenced by outbox rows and pending_attachments.
    test(
      'a re-pull does not overwrite the local uuid with the server one',
      () async {
        await pull([
          {
            'name': 'SO-7',
            'modified': '2026-01-01 00:00:00',
            'customer': 'CUST-7',
            'mobile_uuid': null,
            'items': const <Map<String, dynamic>>[],
          },
        ], isInitialSync: true);
        final first = await db.query('docs__sales_order');
        final localUuid = first.first['mobile_uuid'] as String;

        // Server now reports a uuid for the same record.
        await pull([
          {
            'name': 'SO-7',
            'modified': '2026-01-02 00:00:00',
            'customer': 'CUST-7b',
            'mobile_uuid': serverUuid,
            'items': const <Map<String, dynamic>>[],
          },
        ]);

        final after = await db.query('docs__sales_order');
        expect(after.length, 1);
        expect(
          after.first['mobile_uuid'],
          localUuid,
          reason:
              'the local uuid is already referenced by outbox and '
              'pending_attachments rows; a pull must not renumber it',
        );
        expect(
          after.first['customer'],
          'CUST-7b',
          reason: 'payload still applies',
        );
      },
    );
  });

  group('adoption does not disturb the bulk-vs-sequential gate', () {
    // Regression guard, not new behaviour. Adoption means a local row can now
    // hold a SERVER-originated uuid, and the bulk gate tests incoming uuids
    // with `mobile_uuid IN (...) AND (server_name IS NULL OR server_name =
    // '')`. An adopted row always has a non-empty `server_name`, so it must
    // not match that clause and must not force the whole page onto the slower
    // sequential path. Asserted via the path's own log line, because the
    // stored value is identical either way — only the route differs.
    test('a re-pull of an adopted row still takes the bulk path', () async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      final row = {
        'name': 'SO-8',
        'modified': '2026-01-01 00:00:00',
        'customer': 'CUST-8',
        'mobile_uuid': serverUuid,
        'items': const <Map<String, dynamic>>[],
      };

      await pull([row], isInitialSync: true);
      expect(
        (await db.query('docs__sales_order')).first['mobile_uuid'],
        serverUuid,
      );

      logs.clear();
      // Same page again, still an initial sync — the gate re-evaluates against
      // the row that just adopted its uuid.
      await pull([row], isInitialSync: true);

      expect(
        logs.where((l) => l.contains('Bulk insert')),
        isNotEmpty,
        reason: 'the adopted row must not trip the unsafe-row gate',
      );
      expect(
        logs.where((l) => l.contains('Sequential write')),
        isEmpty,
        reason:
            'a non-empty server_name excludes the row from the gate clause, '
            'so no fallback should occur',
      );
    });
  });
}
