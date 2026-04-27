import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/meta_resolver.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  // Generic parent doctype with a Link, a Table, and a title field.
  final parentMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('customer', 'Link', options: 'Customer'),
      f('items', 'Table', options: 'Order Item'),
    ],
  );
  // Generic child doctype (istable=1).
  final childMeta = DocTypeMeta(
    name: 'Order Item',
    isTable: true,
    fields: [
      f('item_name', 'Data'),
      f('size', 'Data'),
      f('color', 'Select'),
    ],
  );

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();

    // Persist meta JSON so OfflineRepository._loadMeta + LocalWriter's
    // metaResolver can find them.
    await appDb.doctypeMetaDao.upsertMetaJson(
        'Order', jsonEncode(parentMeta.toJson()));
    await appDb.doctypeMetaDao.upsertMetaJson(
        'Order Item', jsonEncode(childMeta.toJson()));

    // Pre-create the per-doctype tables (the closure-pull would do this
    // in production after login).
    for (final s
        in buildParentSchemaDDL(parentMeta, tableName: 'docs__order')) {
      await appDb.rawDatabase.execute(s);
    }
    for (final s
        in buildChildSchemaDDL(childMeta, tableName: 'docs__order_item')) {
      await appDb.rawDatabase.execute(s);
    }

    final writer = LocalWriter(
      appDb.rawDatabase,
      (dt) async {
        final entity = await appDb.doctypeMetaDao.findByDoctype(dt);
        if (entity == null) throw StateError('no meta for $dt');
        return DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
      },
    );
    repo = OfflineRepository(appDb, localWriter: writer);
  });

  tearDown(() async => appDb.rawDatabase.close());

  test(
    'createDocument writes parent + splits children into per-doctype tables',
    () async {
      await repo.createDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': 'p-uuid-1',
          'title': 'offline order 1',
          'customer': 'CUST-001',
          'items': [
            {'item_name': 'item 1', 'size': 'L', 'color': 'Red'},
            {'item_name': 'item 2', 'size': 'M', 'color': 'Blue'},
          ],
        },
      );

      // Legacy store has the parent doc (entire JSON in one row).
      final legacy = await appDb.documentDao.findByDoctype('Order');
      expect(legacy.length, 1);
      expect(legacy.first.status, 'dirty');

      // Per-doctype parent table.
      final parents = await appDb.rawDatabase.query('docs__order');
      expect(parents.length, 1);
      expect(parents.first['mobile_uuid'], 'p-uuid-1');
      expect(parents.first['server_name'], isNull);
      expect(parents.first['sync_status'], 'dirty');
      expect(parents.first['title'], 'offline order 1');

      // Per-child-doctype table — visible to UnifiedResolver/Link picker.
      final children = await appDb.rawDatabase.query(
        'docs__order_item',
        orderBy: 'idx ASC',
      );
      expect(children.length, 2);
      expect(children[0]['parent_uuid'], 'p-uuid-1');
      expect(children[0]['parent_doctype'], 'Order');
      expect(children[0]['parentfield'], 'items');
      expect(children[0]['idx'], 0);
      expect(children[0]['item_name'], 'item 1');
      expect(children[1]['item_name'], 'item 2');
      expect(children[1]['idx'], 1);
    },
  );

  test(
    'updateDocumentData replaces children atomically (delete + insert)',
    () async {
      final initial = await repo.createDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': 'p-uuid-2',
          'title': 'first',
          'items': [
            {'item_name': 'A'},
            {'item_name': 'B'},
            {'item_name': 'C'},
          ],
        },
      );

      await repo.updateDocumentData(
        initial.localId,
        {
          'mobile_uuid': 'p-uuid-2',
          'title': 'updated',
          'items': [
            {'item_name': 'X'},
          ],
        },
      );

      final children = await appDb.rawDatabase.query(
        'docs__order_item',
        orderBy: 'idx ASC',
      );
      expect(children.length, 1);
      expect(children.first['item_name'], 'X');
    },
  );

  test(
    'saveServerDocument promotes the offline-saved row instead of duplicating',
    () async {
      // Step 1: offline save.
      await repo.createDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': 'p-uuid-3',
          'title': 'pending push',
          'customer': 'CUST-001',
          'items': [
            {'item_name': 'offline item'},
          ],
        },
      );

      // Step 2: push completes; server returns name.
      await repo.saveServerDocument(
        doctype: 'Order',
        serverId: 'ORD-00042',
        data: {
          'mobile_uuid': 'p-uuid-3',
          'name': 'ORD-00042',
          'title': 'pending push',
          'customer': 'CUST-001',
          'modified': '2026-04-27 12:00:00',
          'items': [
            {'name': 'ORDI-001', 'item_name': 'offline item'},
          ],
        },
      );

      // The offline-saved row should be promoted, not duplicated.
      final parents = await appDb.rawDatabase.query('docs__order');
      expect(parents.length, 1, reason: 'must not duplicate after writeback');
      expect(parents.first['mobile_uuid'], 'p-uuid-3');
      expect(parents.first['server_name'], 'ORD-00042');
      expect(parents.first['sync_status'], 'synced');
    },
  );

  test(
    'UnifiedResolver returns offline child rows without sync_status error',
    () async {
      // Offline-save a parent with 2 child rows.
      await repo.createDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': 'p-uuid-4',
          'title': 'resolver test',
          'items': [
            {'item_name': 'Alpha', 'size': 'L', 'color': 'Red'},
            {'item_name': 'Beta', 'size': 'S', 'color': 'Green'},
          ],
        },
      );

      // Verify children landed in the child table.
      final childRows = await appDb.rawDatabase.query(
        'docs__order_item',
        where: 'parent_uuid = ?',
        whereArgs: ['p-uuid-4'],
        orderBy: 'idx ASC',
      );
      expect(childRows.length, 2);

      // Build a resolver that reads from the same in-memory DB.
      MetaResolverFn metaFn = (dt) async {
        final entity = await appDb.doctypeMetaDao.findByDoctype(dt);
        if (entity == null) throw StateError('no meta for $dt');
        return DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
      };
      final resolver = UnifiedResolver(
        db: appDb.rawDatabase,
        metaDao: appDb.doctypeMetaDao,
        isOnline: () => false,
        backgroundFetch: (_, __) async {},
        metaResolver: metaFn,
      );

      // Resolving the CHILD doctype must not throw "no such column: sync_status".
      final result = await resolver.resolve(doctype: 'Order Item');
      expect(result.rows.length, 2);
      expect(
        result.rows.map((r) => r['item_name']).toList(),
        containsAll(['Alpha', 'Beta']),
      );
    },
  );
}
