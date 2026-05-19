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
    );
    expect(await repo.getDirtyDocuments(), isEmpty);
    expect(await repo.getDirtyDocuments(doctype: 'Customer'), isEmpty);
    await db.close();
  });

  test(
    'saveDocument throws StateError when client is missing in online mode',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final repo = OfflineRepository(
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      );
      expect(
        () => repo.saveDocument(doctype: 'Customer', data: const {}),
        throwsStateError,
      );
      await db.close();
    },
  );
}
