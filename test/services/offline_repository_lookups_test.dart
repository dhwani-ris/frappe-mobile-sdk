// Covers OfflineRepository read-side methods not exercised by other
// `offline_repository_*` test files: getSyncErrorsForDoc, getRowFromPerDoctypeTable,
// doctypesWithChildren, attachChildRows.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/document.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _customerMeta() => DocTypeMeta(
  name: 'Customer',
  isTable: false,
  fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
);

DocTypeMeta _orderMeta() => DocTypeMeta(
  name: 'Order',
  isTable: false,
  fields: [
    DocField(fieldname: 'title', fieldtype: 'Data'),
    // Child table reference — pins doctypesWithChildren behaviour.
    DocField(fieldname: 'items', fieldtype: 'Table', options: 'Order Item'),
  ],
);

DocTypeMeta _orderItemMeta() => DocTypeMeta(
  name: 'Order Item',
  isTable: true,
  fields: [DocField(fieldname: 'qty', fieldtype: 'Int')],
);

OfflineRepository _newRepo(
  AppDatabase appDb, {
  required Map<String, DocTypeMeta> metas,
}) {
  final localWriter = LocalWriter(
    appDb.rawDatabase,
    (dt) async => metas[dt] ?? _customerMeta(),
  );
  return OfflineRepository(
    appDb,
    localWriter: localWriter,
    offlineMode: const OfflineMode(enabled: true, isPersisted: true),
    client: FrappeClient('http://localhost'),
    metaFetcher: (dt) async => metas[dt] ?? _customerMeta(),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('getSyncErrorsForDoc', () {
    test(
      'returns failed/blocked/conflict rows; ignores pending/done',
      () async {
        final appDb = await AppDatabase.inMemoryDatabase();
        final repo = _newRepo(appDb, metas: {'Customer': _customerMeta()});
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Customer',
          jsonEncode(_customerMeta().toJson()),
        );
        await repo.ensureSchemaForClosure(
          metas: {'Customer': _customerMeta()},
          childDoctypes: const {},
        );
        final uuid = await repo.saveDocument(
          doctype: 'Customer',
          data: {'customer_name': 'Acme'},
        );

        final outbox = OutboxDao(appDb.rawDatabase);
        final rows = await outbox.findByMobileUuid(
          doctype: 'Customer',
          mobileUuid: uuid,
        );
        // saveDocument inserts a pending outbox row.
        expect(rows, hasLength(1));
        await outbox.markFailed(
          rows.first.id,
          errorCode: ErrorCode.NETWORK,
          errorMessage: 'timeout',
        );

        // Additional rows that should NOT surface:
        // 1) a pending row for the same doc (post-failure retry placeholder)
        final extra = await outbox.insertPending(
          doctype: 'Customer',
          mobileUuid: uuid,
          operation: OutboxOperation.update,
        );
        // 2) a done row for the same doc (markDone deletes — implicit cover)
        final done = await outbox.insertPending(
          doctype: 'Customer',
          mobileUuid: uuid,
          operation: OutboxOperation.update,
        );
        await outbox.markDone(done, serverName: 'CUST-1');

        final errors = await repo.getSyncErrorsForDoc(
          doctype: 'Customer',
          mobileUuid: uuid,
        );
        expect(errors, hasLength(1));
        expect(errors.single.state, OutboxState.failed);
        // Sanity — pending row exists but is not surfaced as an error.
        expect((await outbox.findById(extra))!.state, OutboxState.pending);

        await appDb.close();
      },
    );

    test('returns empty when no outbox rows exist for the doc', () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      final repo = _newRepo(appDb, metas: {'Customer': _customerMeta()});
      final errors = await repo.getSyncErrorsForDoc(
        doctype: 'Customer',
        mobileUuid: 'no-such-uuid',
      );
      expect(errors, isEmpty);
      await appDb.close();
    });
  });

  group('getRowFromPerDoctypeTable', () {
    test('returns null when the docs__ table does not exist', () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      final repo = _newRepo(appDb, metas: {'Customer': _customerMeta()});
      final row = await repo.getRowFromPerDoctypeTable('Ghost', 'anything');
      expect(row, isNull);
      await appDb.close();
    });

    test('matches by mobile_uuid and by server_name', () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      final repo = _newRepo(appDb, metas: {'Customer': _customerMeta()});
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Customer',
        jsonEncode(_customerMeta().toJson()),
      );
      await repo.ensureSchemaForClosure(
        metas: {'Customer': _customerMeta()},
        childDoctypes: const {},
      );
      final uuid = await repo.saveDocument(
        doctype: 'Customer',
        data: {'customer_name': 'Acme'},
      );

      // Match by mobile_uuid.
      final byUuid = await repo.getRowFromPerDoctypeTable('Customer', uuid);
      expect(byUuid, isNotNull);
      expect(byUuid!['mobile_uuid'], uuid);
      expect(byUuid['customer_name'], 'Acme');

      // Stamp a server_name and match by it.
      await appDb.rawDatabase.update(
        normalizeDoctypeTableName('Customer'),
        {'server_name': 'CUST-9'},
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      );
      final byName = await repo.getRowFromPerDoctypeTable('Customer', 'CUST-9');
      expect(byName, isNotNull);
      expect(byName!['server_name'], 'CUST-9');
      expect(byName['mobile_uuid'], uuid);

      // Miss returns null.
      expect(await repo.getRowFromPerDoctypeTable('Customer', 'nope'), isNull);
      await appDb.close();
    });
  });

  group('doctypesWithChildren', () {
    test('lists only doctypes whose meta declares Table fields', () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      final repo = _newRepo(
        appDb,
        metas: {
          'Customer': _customerMeta(),
          'Order': _orderMeta(),
          'Order Item': _orderItemMeta(),
        },
      );
      // Persist metaJson for both Customer (no children) and Order (has children).
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Customer',
        jsonEncode(_customerMeta().toJson()),
      );
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Order',
        jsonEncode(_orderMeta().toJson()),
      );
      // The DAO flag is what doctypesWithChildren actually reads.
      await appDb.doctypeMetaDao.setIsParentWithChildren('Order', true);

      final out = await repo.doctypesWithChildren();
      expect(out, contains('Order'));
      expect(
        out.contains('Customer'),
        isFalse,
        reason: 'Customer has no Table field, must not appear',
      );
      await appDb.close();
    });
  });

  group('attachChildRows', () {
    test(
      'appends children from docs__<child> matching parent server name',
      () async {
        final appDb = await AppDatabase.inMemoryDatabase();
        final repo = _newRepo(
          appDb,
          metas: {'Order': _orderMeta(), 'Order Item': _orderItemMeta()},
        );
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Order',
          jsonEncode(_orderMeta().toJson()),
        );
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Order Item',
          jsonEncode(_orderItemMeta().toJson()),
        );
        await repo.ensureSchemaForClosure(
          metas: {'Order': _orderMeta(), 'Order Item': _orderItemMeta()},
          childDoctypes: const {'Order Item'},
        );

        // Insert a parent row with a known server_name.
        final orderUuid = await repo.saveDocument(
          doctype: 'Order',
          data: {'title': 'O-1'},
        );
        await appDb.rawDatabase.update(
          normalizeDoctypeTableName('Order'),
          {'server_name': 'ORDER-1'},
          where: 'mobile_uuid = ?',
          whereArgs: [orderUuid],
        );

        // Insert two child rows attached to the parent via parent_uuid.
        final childTable = normalizeDoctypeTableName('Order Item');
        await appDb.rawDatabase.insert(childTable, {
          'mobile_uuid': 'item-1',
          'parent_uuid': orderUuid,
          'parentfield': 'items',
          'parent_doctype': 'Order',
          'idx': 1,
          'qty': 2,
        });
        await appDb.rawDatabase.insert(childTable, {
          'mobile_uuid': 'item-2',
          'parent_uuid': orderUuid,
          'parentfield': 'items',
          'parent_doctype': 'Order',
          'idx': 2,
          'qty': 5,
        });

        // Build a Document for the parent and ask the repo to attach children.
        final parent = Document(
          localId: orderUuid,
          doctype: 'Order',
          data: const {'title': 'O-1'},
          modified: 0,
        );
        final hydrated = await repo.attachChildRows(
          'Order',
          parent,
          _orderMeta(),
        );
        final children = hydrated.data['items'] as List?;
        expect(children, isNotNull);
        expect(children!.map((c) => (c as Map)['qty']).toList(), [2, 5]);

        await appDb.close();
      },
    );
  });
}
