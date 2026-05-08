import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _customerMeta() => DocTypeMeta(
  name: 'Customer',
  isTable: false,
  fields: [
    DocField(fieldname: 'customer_name', fieldtype: 'Data'),
    DocField(fieldname: 'amount', fieldtype: 'Currency'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    final localWriter = LocalWriter(
      appDb.rawDatabase,
      (_) async => _customerMeta(),
    );
    repo = OfflineRepository(
      appDb,
      localWriter: localWriter,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: FrappeClient('http://localhost'),
      metaFetcher: (_) async => _customerMeta(),
    );
    // Persist metaJson so DAO updates (setTableName / saveDocument's
    // _loadMeta) hit a real row. Production: MetaService.getMeta does
    // this before any save can happen.
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Customer',
      jsonEncode(_customerMeta().toJson()),
    );
    await repo.ensureSchemaForClosure(
      metas: {'Customer': _customerMeta()},
      childDoctypes: const {},
    );
  });

  tearDown(() async => appDb.close());

  test(
    'saveDocument INSERT writes docs__ row + outbox row in one txn',
    () async {
      final uuid = await repo.saveDocument(
        doctype: 'Customer',
        data: {'customer_name': 'Acme', 'amount': 100},
      );
      expect(uuid, isNotEmpty);
      final docs = await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Customer'),
      );
      expect(docs.length, 1);
      expect(docs[0]['mobile_uuid'], uuid);
      expect(docs[0]['sync_status'], 'dirty');
      expect(docs[0]['sync_op'], 'INSERT');
      expect(docs[0]['customer_name'], 'Acme');

      final outbox = await appDb.rawDatabase.query('outbox');
      expect(outbox.length, 1);
      expect(outbox[0]['operation'], 'INSERT');
      expect(outbox[0]['mobile_uuid'], uuid);
    },
  );

  test('saveDocument UPDATE captures push_base_payload once', () async {
    final uuid = await repo.saveDocument(
      doctype: 'Customer',
      data: {'customer_name': 'Acme', 'amount': 100},
    );
    // Promote to synced (simulates a successful push).
    await appDb.rawDatabase.update(
      normalizeDoctypeTableName('Customer'),
      {
        'sync_status': 'synced',
        'server_name': 'CUST-001',
        'push_base_payload': null,
      },
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    );
    await appDb.rawDatabase.delete('outbox');

    // First edit — base captured.
    await repo.saveDocument(
      doctype: 'Customer',
      data: {'mobile_uuid': uuid, 'customer_name': 'Acme2', 'amount': 100},
    );
    final firstBase =
        (await appDb.rawDatabase.query(
              normalizeDoctypeTableName('Customer'),
              where: 'mobile_uuid = ?',
              whereArgs: [uuid],
            )).first['push_base_payload']
            as String?;
    expect(firstBase, isNotNull);
    final firstParsed = jsonDecode(firstBase!) as Map;
    expect(firstParsed['customer_name'], 'Acme');

    // Second edit — base must NOT be overwritten.
    await repo.saveDocument(
      doctype: 'Customer',
      data: {'mobile_uuid': uuid, 'customer_name': 'Acme3', 'amount': 200},
    );
    final secondBase =
        (await appDb.rawDatabase.query(
              normalizeDoctypeTableName('Customer'),
              where: 'mobile_uuid = ?',
              whereArgs: [uuid],
            )).first['push_base_payload']
            as String?;
    expect(secondBase, firstBase, reason: 'base preserved across edits');
  });

  test(
    'deleteDocument tombstones synced docs__ row + enqueues DELETE',
    () async {
      final uuid = await repo.saveDocument(
        doctype: 'Customer',
        data: {'customer_name': 'Acme', 'amount': 100},
      );
      // Promote to synced so DELETE doesn't trigger the cancel-INSERT path.
      await appDb.rawDatabase.update(
        normalizeDoctypeTableName('Customer'),
        {'sync_status': 'synced', 'server_name': 'CUST-001'},
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      );
      await appDb.rawDatabase.delete('outbox');

      await repo.deleteDocument(doctype: 'Customer', mobileUuid: uuid);

      final docs = await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Customer'),
      );
      expect(docs.length, 1);
      expect(docs[0]['sync_status'], 'deleted');
      expect(docs[0]['sync_op'], 'DELETE');

      final outbox = await appDb.rawDatabase.query('outbox');
      expect(outbox.length, 1);
      expect(outbox[0]['operation'], 'DELETE');
    },
  );

  test(
    'deleteDocument on never-pushed doc cancels INSERT and hard-deletes',
    () async {
      final uuid = await repo.saveDocument(
        doctype: 'Customer',
        data: {'customer_name': 'Acme'},
      );
      await repo.deleteDocument(doctype: 'Customer', mobileUuid: uuid);
      final docs = await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Customer'),
      );
      expect(
        docs,
        isEmpty,
        reason: 'docs__ row hard-deleted when INSERT cancelled',
      );
      final outbox = await appDb.rawDatabase.query('outbox');
      expect(outbox, isEmpty);
    },
  );

  test(
    'getDirtyDocuments surfaces dirty + deleted rows after offline saves',
    () async {
      // Two dirty offline saves.
      await repo.saveDocument(
        doctype: 'Customer',
        data: {'customer_name': 'Alpha'},
      );
      final betaUuid = await repo.saveDocument(
        doctype: 'Customer',
        data: {'customer_name': 'Beta'},
      );

      // Promote one to synced, then tombstone it (hits the deleted bucket).
      await appDb.rawDatabase.update(
        normalizeDoctypeTableName('Customer'),
        {'sync_status': 'synced', 'server_name': 'CUST-100'},
        where: 'mobile_uuid = ?',
        whereArgs: [betaUuid],
      );
      await appDb.rawDatabase.delete(
        'outbox',
        where: 'mobile_uuid = ?',
        whereArgs: [betaUuid],
      );
      await repo.deleteDocument(doctype: 'Customer', mobileUuid: betaUuid);

      // Default scan finds both. Filtered scan also finds them.
      final dirtyAll = await repo.getDirtyDocuments();
      expect(dirtyAll.length, 2);
      final statuses = dirtyAll.map((d) => d.status).toSet();
      expect(statuses, containsAll(<String>{'dirty', 'deleted'}));

      final dirtyForCustomer = await repo.getDirtyDocuments(
        doctype: 'Customer',
      );
      expect(dirtyForCustomer.length, 2);

      // Filter to a doctype with no dirty rows → empty.
      final dirtyForOther = await repo.getDirtyDocuments(
        doctype: 'NoSuchDoctype',
      );
      expect(dirtyForOther, isEmpty);
    },
  );

  test(
    'saveDocument does not deadlock when meta cache is empty (DAO read path)',
    () async {
      // Build a fresh repo with NO metaFetcher and a metaResolver that
      // throws — the only way meta can be obtained is via `_loadMeta`'s
      // DAO query. This forces the in-txn deadlock path (a real-DB read
      // queued behind the in-flight write txn) to fire if we ever
      // re-introduce the bug.
      final db2 = await AppDatabase.inMemoryDatabase();
      await db2.doctypeMetaDao.upsertMetaJson(
        'Customer',
        jsonEncode(_customerMeta().toJson()),
      );
      final localWriter = LocalWriter(
        db2.rawDatabase,
        // Throwing resolver — if anyone hits it inside the txn we'll see.
        (_) async => throw StateError('metaResolver should not be called'),
      );
      final repo2 = OfflineRepository(
        db2,
        localWriter: localWriter,
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        client: FrappeClient('http://localhost'),
        // No metaFetcher → _loadMeta MUST go through doctypeMetaDao.
      );
      await repo2.ensureSchemaForClosure(
        metas: {'Customer': _customerMeta()},
        childDoctypes: const {},
      );
      // Fast-fail timeout proves we don't deadlock — the bug presented
      // as a 30s lock-warning hang.
      await repo2
          .saveDocument(doctype: 'Customer', data: {'customer_name': 'NoCache'})
          .timeout(const Duration(seconds: 5));
      final rows = await db2.rawDatabase.query(
        normalizeDoctypeTableName('Customer'),
      );
      expect(rows, hasLength(1));
      await db2.close();
    },
  );

  test(
    'deleteDocument does not deadlock when meta cache is empty (DAO read path)',
    () async {
      final db2 = await AppDatabase.inMemoryDatabase();
      await db2.doctypeMetaDao.upsertMetaJson(
        'Customer',
        jsonEncode(_customerMeta().toJson()),
      );
      final localWriter = LocalWriter(
        db2.rawDatabase,
        (_) async => throw StateError('metaResolver should not be called'),
      );
      final repo2 = OfflineRepository(
        db2,
        localWriter: localWriter,
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        client: FrappeClient('http://localhost'),
      );
      await repo2.ensureSchemaForClosure(
        metas: {'Customer': _customerMeta()},
        childDoctypes: const {},
      );
      final uuid = await repo2
          .saveDocument(doctype: 'Customer', data: {'customer_name': 'X'})
          .timeout(const Duration(seconds: 5));
      // Drop the cache so deleteDocument's _loadMeta has to hit the DAO.
      repo2.invalidateMetaCache();
      await repo2
          .deleteDocument(doctype: 'Customer', mobileUuid: uuid)
          .timeout(const Duration(seconds: 5));
      await db2.close();
    },
  );

  test('getDirtyDocuments returns empty in online mode', () async {
    // Save offline first so docs__ has rows...
    await repo.saveDocument(
      doctype: 'Customer',
      data: {'customer_name': 'Acme'},
    );
    // ...then build a second repo whose mode is online; it should
    // short-circuit even though docs__ is non-empty.
    final onlineRepo = OfflineRepository(
      appDb,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: FrappeClient('http://localhost'),
    );
    expect(await onlineRepo.getDirtyDocuments(), isEmpty);
  });
}
