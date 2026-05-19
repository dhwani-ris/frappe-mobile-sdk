import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
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
  late OutboxDao outbox;

  final orderMeta = DocTypeMeta(
    name: 'Order',
    titleField: 'title',
    fields: [
      f('title', 'Data'),
      f('customer', 'Link', options: 'Customer'),
    ],
  );

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Order',
      jsonEncode(orderMeta.toJson()),
    );

    for (final s in buildParentSchemaDDL(orderMeta, tableName: 'docs__order')) {
      await appDb.rawDatabase.execute(s);
    }

    final writer = LocalWriter(appDb.rawDatabase, (dt) async {
      final entity = await appDb.doctypeMetaDao.findByDoctype(dt);
      if (entity == null) throw StateError('no meta for $dt');
      return DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
    });
    repo = OfflineRepository(appDb, localWriter: writer);
    outbox = OutboxDao(appDb.rawDatabase);
  });

  tearDown(() async => appDb.rawDatabase.close());

  test(
    'reconcileServerSave: failed offline lineage collapses into one synced row',
    () async {
      // Arrange: a previously-saved offline doc that the push rejected.
      // docs__order has the row at mobile_uuid=X with sync_status=dirty
      // and no server_name; outbox carries one failed INSERT.
      const mobileUuid = 'X-uuid';
      await repo.saveDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': mobileUuid,
          'title': 'first try',
          'customer': 'CUST-001',
        },
      );
      // Move the auto-enqueued INSERT row to `failed` to simulate
      // PushEngine giving up after a server validation error.
      final pendings = await outbox.findByState(OutboxState.pending);
      expect(pendings.length, 1);
      await outbox.markFailed(
        pendings.first.id,
        errorCode: ErrorCode.UNKNOWN,
        errorMessage: 'LinkValidationError: Could not find Row #1',
      );

      // Act: a successful server-first retry comes back with a real
      // server name. The form code calls reconcileServerSave with the
      // SAME mobile_uuid (identity preserved).
      const serverName = 'ORDER-00001';
      await repo.reconcileServerSave(
        doctype: 'Order',
        mobileUuid: mobileUuid,
        serverName: serverName,
        serverData: {
          'name': serverName,
          'mobile_uuid': mobileUuid,
          'title': 'second try fixed',
          'customer': 'CUST-001',
          'modified': '2026-05-08 18:00:00',
        },
      );

      // Assert 1: docs__order has exactly ONE row, the original lineage,
      // now stamped synced with the server_name attached.
      final rows = await appDb.rawDatabase.query('docs__order');
      expect(rows.length, 1, reason: 'lineage must not fork into a 2nd row');
      expect(rows.first['mobile_uuid'], mobileUuid);
      expect(rows.first['server_name'], serverName);
      expect(rows.first['sync_status'], 'synced');
      expect(
        rows.first['title'],
        'second try fixed',
        reason: 'server snapshot must apply on top of the existing row',
      );

      // Assert 2: the failed outbox row is gone — the doc is on the
      // server now, no INSERT/UPDATE is owed.
      final remaining = await appDb.rawDatabase.query('outbox');
      expect(
        remaining,
        isEmpty,
        reason: 'reconcile must clear the stale failed row',
      );
    },
  );

  test(
    'reconcileServerSave is a no-op on outbox for clean documents',
    () async {
      const mobileUuid = 'Y-uuid';
      await repo.saveDocument(
        doctype: 'Order',
        data: {
          'mobile_uuid': mobileUuid,
          'title': 'fresh',
          'customer': 'CUST-002',
        },
      );

      // Pretend the auto-enqueued INSERT ran cleanly: simulate
      // PushEngine.markDone by deleting the row.
      final pendings = await outbox.findByState(OutboxState.pending);
      await outbox.markDone(pendings.first.id, serverName: 'ORDER-00002');

      const serverName = 'ORDER-00002';
      await repo.reconcileServerSave(
        doctype: 'Order',
        mobileUuid: mobileUuid,
        serverName: serverName,
        serverData: {
          'name': serverName,
          'mobile_uuid': mobileUuid,
          'title': 'fresh',
          'customer': 'CUST-002',
          'modified': '2026-05-08 19:00:00',
        },
      );

      final rows = await appDb.rawDatabase.query('docs__order');
      expect(rows.length, 1);
      expect(rows.first['server_name'], serverName);
      expect(rows.first['sync_status'], 'synced');
    },
  );
}
