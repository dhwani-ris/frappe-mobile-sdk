import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('pushSync returns empty SyncResult in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FrappeClient('http://localhost');
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: client,
    );
    final sync = SyncService(
      client,
      repo,
      db,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );

    final result = await sync.pushSync();
    expect(result.success, 0);
    expect(result.failed, 0);
    expect(result.total, 0);
    expect(result.error, isNull);
    await db.close();
  });

  test('pullSync returns empty SyncResult in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FrappeClient('http://localhost');
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: client,
    );
    final sync = SyncService(
      client,
      repo,
      db,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );

    final result = await sync.pullSync(doctype: 'Customer');
    expect(result.success, 0);
    expect(result.total, 0);
    await db.close();
  });

  test(
    'pullSyncMany returns empty SyncResults per doctype in online mode',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final client = FrappeClient('http://localhost');
      final repo = OfflineRepository(
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
        client: client,
      );
      final sync = SyncService(
        client,
        repo,
        db,
        getMobileUuid: () async => 'test-uuid',
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      );

      final results = await sync.pullSyncMany(
        doctypes: ['Customer', 'Supplier', 'State'],
      );
      expect(results.keys, ['Customer', 'Supplier', 'State']);
      for (final r in results.values) {
        expect(r.success, 0);
        expect(r.failed, 0);
        expect(r.total, 0);
      }
      await db.close();
    },
  );

  test('pullSyncMany with empty doctype list returns empty map', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FrappeClient('http://localhost');
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: client,
    );
    final sync = SyncService(
      client,
      repo,
      db,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
    );

    // No isOnline gate is reached when offlineMode disabled; with mode
    // enabled and an empty list the result must still be empty without
    // exercising the network — verifies `pullSyncMany` short-circuits
    // cleanly on empty input.
    final results = await sync.pullSyncMany(doctypes: []);
    expect(results, isEmpty);
    await db.close();
  });

  test('getSyncStats returns zeros in online mode', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FrappeClient('http://localhost');
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: client,
    );
    final sync = SyncService(
      client,
      repo,
      db,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );

    final stats = await sync.getSyncStats();
    expect(stats['dirty'], 0);
    expect(stats['deleted'], 0);
    expect(stats['total'], 0);
    await db.close();
  });
}
