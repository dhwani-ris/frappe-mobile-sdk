// Covers the LRU cache + DB-first read path of MetaService.getMeta /
// getMetas / deleteMeta / clearCache that the existing meta_service_test
// doesn't pin directly. The 15-entry LRU eviction is the most likely
// source of "stale meta returned after a refresh" bugs, so we exercise
// it directly.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/meta_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta(String name, [String firstField = 'name']) => DocTypeMeta(
  name: name,
  isTable: false,
  fields: [DocField(fieldname: firstField, fieldtype: 'Data')],
);

Future<void> _seed(AppDatabase appDb, DocTypeMeta meta) async {
  await appDb.doctypeMetaDao.insertDoctypeMeta(
    DoctypeMetaEntity(
      doctype: meta.name,
      modified: null,
      serverModifiedAt: null,
      isMobileForm: false,
      metaJson: jsonEncode(meta.toJson()),
    ),
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('getMeta serves from DB when no cache entry exists', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    await _seed(appDb, _meta('Customer'));
    final svc = MetaService(FrappeClient('http://localhost'), appDb);

    final m = await svc.getMeta('Customer');
    expect(m.name, 'Customer');
    expect(m.fields, hasLength(1));
    await appDb.close();
  });

  test('getMeta on a second call returns the cached instance', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    await _seed(appDb, _meta('Customer'));
    final svc = MetaService(FrappeClient('http://localhost'), appDb);

    final m1 = await svc.getMeta('Customer');
    final m2 = await svc.getMeta('Customer');
    expect(
      identical(m1, m2),
      isTrue,
      reason: 'cached meta must be served as the same object',
    );
    await appDb.close();
  });

  test(
    'getMeta with forceRefresh=true bypasses cache AND DB and hits server',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      await _seed(appDb, _meta('Customer'));
      final svc = MetaService(FrappeClient('http://localhost'), appDb);

      await svc.getMeta('Customer'); // warm cache
      // forceRefresh=true forces _fetchMetaFromServer, which calls the wired
      // FrappeClient — no http mocking here, so we expect a NetworkException.
      await expectLater(
        svc.getMeta('Customer', forceRefresh: true),
        throwsA(isException),
      );
      await appDb.close();
    },
  );

  test('clearCache empties LRU; next read re-reads DB', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    await _seed(appDb, _meta('Customer', 'name1'));
    final svc = MetaService(FrappeClient('http://localhost'), appDb);

    final m1 = await svc.getMeta('Customer');
    svc.clearCache();
    final m2 = await svc.getMeta('Customer');
    // Different objects post-clear; both equivalent.
    expect(identical(m1, m2), isFalse);
    expect(m2.fields.first.fieldname, 'name1');
    await appDb.close();
  });

  test('clearDocTypeCache only evicts the named doctype', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    await _seed(appDb, _meta('Customer'));
    await _seed(appDb, _meta('Supplier'));
    final svc = MetaService(FrappeClient('http://localhost'), appDb);

    final c1 = await svc.getMeta('Customer');
    final s1 = await svc.getMeta('Supplier');
    svc.clearDocTypeCache('Customer');
    final c2 = await svc.getMeta('Customer');
    final s2 = await svc.getMeta('Supplier');

    expect(identical(c1, c2), isFalse, reason: 'Customer was evicted');
    expect(identical(s1, s2), isTrue, reason: 'Supplier stayed cached');
    await appDb.close();
  });

  test('LRU eviction kicks in after 15 cached entries', () async {
    // Pins _kMetaCacheMaxSize semantic without coupling to the constant —
    // we observe that the 1st-cached doctype gets evicted after a 16th
    // distinct meta has been loaded.
    final appDb = await AppDatabase.inMemoryDatabase();
    for (var i = 0; i < 16; i++) {
      await _seed(appDb, _meta('DT$i', 'f$i'));
    }
    final svc = MetaService(FrappeClient('http://localhost'), appDb);
    final first = await svc.getMeta('DT0');
    for (var i = 1; i < 16; i++) {
      await svc.getMeta('DT$i');
    }
    final firstAgain = await svc.getMeta('DT0');
    expect(
      identical(first, firstAgain),
      isFalse,
      reason: 'DT0 must have been evicted by the LRU when DT15 entered',
    );
    await appDb.close();
  });

  test('deleteMeta removes from DB and from cache', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    await _seed(appDb, _meta('Customer'));
    final svc = MetaService(FrappeClient('http://localhost'), appDb);
    await svc.getMeta('Customer'); // warm cache

    await svc.deleteMeta('Customer');

    // DB row gone.
    final row = await appDb.doctypeMetaDao.findByDoctype('Customer');
    expect(row, isNull);
    // Subsequent getMeta would need to hit the server; with no http mock,
    // expect NetworkException. (Proves cache was cleared, not served.)
    await expectLater(svc.getMeta('Customer'), throwsA(isException));
    await appDb.close();
  });

  test('getMetas skips doctypes that throw and still returns the rest', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    await _seed(appDb, _meta('Customer'));
    // 'Ghost' is NOT seeded — DB miss will fall through to _fetchMetaFromServer
    // which throws (no http available).
    final svc = MetaService(FrappeClient('http://localhost'), appDb);

    final out = await svc.getMetas(['Customer', 'Ghost']);
    expect(out.keys, ['Customer']);
    expect(out['Customer']!.name, 'Customer');
    await appDb.close();
  });
}
