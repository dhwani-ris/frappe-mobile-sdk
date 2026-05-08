import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/response_writeback.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
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
}
