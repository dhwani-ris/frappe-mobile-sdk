// Pins the wiring between SyncController.resolveConflict (empty-serverName
// branch) and the builder-supplied clearLocalConflict closure that flips
// `docs__<doctype>.sync_status` from 'conflict' back to 'dirty'.
//
// This is the PR#36 fix path — without the hook, a conflicting INSERT that
// never reached the server would leave the local row visually stuck in
// "conflict" forever even though the outbox row gets closed.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/sync_controller.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _customerMeta() => DocTypeMeta(
  name: 'Customer',
  autoname: 'field:mobile_uuid',
  fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'resolveConflict(pullAndOverwrite, serverName="") flips docs__ row from conflict → dirty',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      // Stand up a Customer docs__ table so clearLocalConflict has a target.
      for (final ddl in buildParentSchemaDDL(
        _customerMeta(),
        tableName: 'docs__customer',
      )) {
        await appDb.rawDatabase.execute(ddl);
      }
      await appDb.doctypeMetaDao.upsertMetaJson('Customer', '{}');
      await appDb.doctypeMetaDao.setTableName('Customer', 'docs__customer');

      // Seed a local row stuck in conflict — no server_name, just like an
      // INSERT that never reached the server.
      const uuid = 'u-c-1';
      await appDb.rawDatabase.insert('docs__customer', {
        'mobile_uuid': uuid,
        'customer_name': 'Acme',
        'sync_status': 'conflict',
        'sync_error': 'TIMESTAMP_MISMATCH',
        'local_modified': 1,
      });

      final outbox = OutboxDao(appDb.rawDatabase);
      final outboxId = await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: uuid,
        operation: OutboxOperation.insert,
      );
      await outbox.markConflict(outboxId, errorMessage: 'mismatch');

      final pack = await SyncEngineBuilder.build(
        database: appDb,
        client: FrappeClient('http://localhost'),
        metaResolver: (_) async => _customerMeta(),
        runPullFn: () async => const <String>{},
        applyServerDoc: (_, _) async {},
        runPullForDoctypes: (_) async {},
      );

      await pack.controller.resolveConflict(
        outboxId: outboxId,
        action: ConflictAction.pullAndOverwriteLocal,
      );

      // Outbox row closed.
      expect(await outbox.findById(outboxId), isNull);

      // docs__ row flipped back to dirty, sync_error cleared. PR#36 fix.
      final row = (await appDb.rawDatabase.query(
        'docs__customer',
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).first;
      expect(row['sync_status'], 'dirty');
      expect(row['sync_error'], isNull);

      await appDb.close();
    },
  );

  test(
    'resolveConflict(pullAndOverwrite, serverName="") on a row that is NOT in conflict is a no-op',
    () async {
      // Pins the WHERE clause: clearLocalConflict updates only rows currently
      // marked conflict — so it cannot accidentally clobber a row the user
      // edited again after the outbox row was reset.
      final appDb = await AppDatabase.inMemoryDatabase();
      for (final ddl in buildParentSchemaDDL(
        _customerMeta(),
        tableName: 'docs__customer',
      )) {
        await appDb.rawDatabase.execute(ddl);
      }
      await appDb.doctypeMetaDao.upsertMetaJson('Customer', '{}');
      await appDb.doctypeMetaDao.setTableName('Customer', 'docs__customer');

      const uuid = 'u-c-2';
      // dirty state, with a stale sync_error from a prior failure — clear-on-
      // conflict must NOT touch this.
      await appDb.rawDatabase.insert('docs__customer', {
        'mobile_uuid': uuid,
        'customer_name': 'Beta',
        'sync_status': 'dirty',
        'sync_error': 'PREVIOUS_NETWORK',
        'local_modified': 1,
      });

      final outbox = OutboxDao(appDb.rawDatabase);
      final outboxId = await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: uuid,
        operation: OutboxOperation.insert,
      );
      await outbox.markConflict(outboxId, errorMessage: 'mismatch');

      final pack = await SyncEngineBuilder.build(
        database: appDb,
        client: FrappeClient('http://localhost'),
        metaResolver: (_) async => _customerMeta(),
        runPullFn: () async => const <String>{},
        applyServerDoc: (_, _) async {},
        runPullForDoctypes: (_) async {},
      );

      await pack.controller.resolveConflict(
        outboxId: outboxId,
        action: ConflictAction.pullAndOverwriteLocal,
      );

      final row = (await appDb.rawDatabase.query(
        'docs__customer',
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).first;
      expect(row['sync_status'], 'dirty');
      expect(
        row['sync_error'],
        'PREVIOUS_NETWORK',
        reason: 'clear-on-conflict must not touch non-conflict rows',
      );

      await appDb.close();
    },
  );
}
