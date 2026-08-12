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

/// B43 (Sync Data page slow): getDirtyDocuments used to do O(N) sequential
/// per-doctype table + column existence probes before each query. The rewrite
/// reads table existence (table names) + `sync_status` presence (CREATE DDL)
/// from a single `sqlite_master` scan. These tests pin the OBSERVABLE contract
/// (which rows come back, missing-table / no-sync_status tolerance) so the perf
/// refactor cannot silently drop or mis-scan dirty docs.
DocTypeMeta _meta(String name) => DocTypeMeta(
  name: name,
  isTable: false,
  fields: [DocField(fieldname: 'title', fieldtype: 'Data')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  final metas = {'Customer': _meta('Customer'), 'Supplier': _meta('Supplier')};
  DocTypeMeta metaFor(String dt) => metas[dt] ?? _meta(dt);

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    final localWriter = LocalWriter(
      appDb.rawDatabase,
      (dt) async => metaFor(dt),
    );
    repo = OfflineRepository(
      appDb,
      localWriter: localWriter,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: FrappeClient('http://localhost'),
      metaFetcher: (dt) async => metaFor(dt),
    );
    for (final e in metas.entries) {
      await appDb.doctypeMetaDao.upsertMetaJson(
        e.key,
        jsonEncode(e.value.toJson()),
      );
    }
    await repo.ensureSchemaForClosure(metas: metas, childDoctypes: const {});
  });

  tearDown(() async => appDb.close());

  Future<void> insertRow(String doctype, String uuid, String status) async {
    await appDb.rawDatabase.insert(normalizeDoctypeTableName(doctype), {
      'mobile_uuid': uuid,
      'sync_status': status,
      'local_modified': DateTime.now().millisecondsSinceEpoch,
      'title': 'row-$uuid',
    });
  }

  test(
    'returns dirty/deleted/error/blocked across tables, excludes synced/clean',
    () async {
      await insertRow('Customer', 'c1', 'dirty');
      await insertRow('Customer', 'c2', 'synced'); // excluded
      await insertRow('Customer', 'c3', 'sync_error');
      await insertRow('Supplier', 's1', 'deleted');
      await insertRow('Supplier', 's2', 'sync_blocked');
      await insertRow('Supplier', 's3', 'clean'); // excluded

      final docs = await repo.getDirtyDocuments();

      expect(docs.length, 4);
      // The four pending states all come back; Document.status collapses
      // sync_error/sync_blocked to 'sync_error', so assert the raw column to
      // prove every WHERE-clause state was actually fetched.
      expect(docs.map((d) => d.data['sync_status']).toSet(), {
        'dirty',
        'sync_error',
        'deleted',
        'sync_blocked',
      });
      expect(docs.map((d) => d.doctype).toSet(), {'Customer', 'Supplier'});
    },
  );

  test('single-doctype scan only touches that table', () async {
    await insertRow('Customer', 'c1', 'dirty');
    await insertRow('Customer', 'c3', 'sync_error');
    await insertRow('Supplier', 's1', 'deleted');

    final docs = await repo.getDirtyDocuments(doctype: 'Customer');

    expect(docs.length, 2);
    expect(docs.every((d) => d.doctype == 'Customer'), isTrue);
  });

  test(
    'tolerates a doctype_meta row whose docs__ table does not exist',
    () async {
      await insertRow('Customer', 'c1', 'dirty');
      // Ghost is enrolled in doctype_meta with a table_name but no table exists.
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Ghost',
        jsonEncode(_meta('Ghost').toJson()),
      );
      await appDb.doctypeMetaDao.setTableName('Ghost', 'docs__ghost');

      final docs = await repo.getDirtyDocuments(); // must not throw

      expect(docs.length, 1);
      expect(docs.single.doctype, 'Customer');
    },
  );

  test(
    'skips a table that has no sync_status column (child/link table)',
    () async {
      await insertRow('Customer', 'c1', 'dirty');
      // A child-style table without a sync_status column.
      await appDb.rawDatabase.execute(
        'CREATE TABLE docs__childthing (mobile_uuid TEXT, title TEXT)',
      );
      await appDb.rawDatabase.insert('docs__childthing', {
        'mobile_uuid': 'x1',
        'title': 'child',
      });
      await appDb.doctypeMetaDao.upsertMetaJson(
        'ChildThing',
        jsonEncode(_meta('ChildThing').toJson()),
      );
      await appDb.doctypeMetaDao.setTableName('ChildThing', 'docs__childthing');

      final docs = await repo.getDirtyDocuments(); // must not throw

      expect(docs.length, 1);
      expect(docs.single.doctype, 'Customer');
    },
  );

  test('online mode short-circuits to empty (outbox is canonical)', () async {
    final onlineRepo = OfflineRepository(
      appDb,
      localWriter: LocalWriter(appDb.rawDatabase, (dt) async => metaFor(dt)),
      offlineMode: const OfflineMode(enabled: false, isPersisted: false),
      client: FrappeClient('http://localhost'),
      metaFetcher: (dt) async => metaFor(dt),
    );
    await insertRow('Customer', 'c1', 'dirty');
    expect(await onlineRepo.getDirtyDocuments(), isEmpty);
  });
}
