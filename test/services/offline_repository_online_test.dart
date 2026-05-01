import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('getDirtyDocuments returns empty in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      // client null is fine — getDirtyDocuments short-circuits before
      // touching the client.
    );
    final dirty = await repo.getDirtyDocuments();
    expect(dirty, isEmpty);
    await db.close();
  });

  test('getDirtyDocumentsByDoctype returns empty in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );
    final dirty = await repo.getDirtyDocumentsByDoctype('Customer');
    expect(dirty, isEmpty);
    await db.close();
  });

  test('createDocument throws StateError when client is missing', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );
    expect(
      () => repo.createDocument(doctype: 'Customer', data: const {}),
      throwsStateError,
    );
    await db.close();
  });
}
