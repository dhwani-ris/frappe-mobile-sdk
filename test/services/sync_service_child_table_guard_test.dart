import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late SyncService sync;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
    final client = FrappeClient('http://localhost');
    final repo = OfflineRepository(db, client: client);
    sync = SyncService(client, repo, db);
  });

  tearDown(() async => await db.close());

  Future<void> persistMeta(String doctype, {required bool isTable}) async {
    final meta = DocTypeMeta(
      name: doctype,
      isTable: isTable,
      fields: [DocField(fieldname: 'foo', fieldtype: 'Data', label: 'Foo')],
    );
    await db.doctypeMetaDao.upsertMetaJson(doctype, jsonEncode(meta.toJson()));
  }

  test('child doctype (istable=1) → guard returns true', () async {
    await persistMeta('Household Survey Family Member', isTable: true);
    expect(
      await sync.isChildTableForTest('Household Survey Family Member'),
      isTrue,
    );
  });

  test('parent doctype (istable=0) → guard returns false', () async {
    await persistMeta('Household Survey', isTable: false);
    expect(await sync.isChildTableForTest('Household Survey'), isFalse);
  });

  test('unknown doctype with no meta on file → defensive false', () async {
    expect(
      await sync.isChildTableForTest('Never Seen Doctype'),
      isFalse,
      reason:
          'must NOT silently skip an unknown doctype; better to attempt '
          'the pull and let the API drive the failure mode',
    );
  });

  test('malformed meta JSON → false (parse failure does not skip)', () async {
    await db.doctypeMetaDao.upsertMetaJson(
      'Broken Doctype',
      '{this is not json}',
    );
    expect(await sync.isChildTableForTest('Broken Doctype'), isFalse);
  });
}
