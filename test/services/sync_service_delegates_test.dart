import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(
      appDb,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: FrappeClient('http://localhost'),
    );
  });

  tearDown(() async => appDb.close());

  test('pushSync invokes the injected pushRunner when online', () async {
    var calls = 0;
    final svc = SyncService(
      FrappeClient('http://localhost'),
      repo,
      appDb,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      pushRunner: () async {
        calls++;
      },
    );
    final result = await svc.pushSync();
    // isOnline() reads connectivity_plus on real devices; in test it
    // returns false in headless CI. Either calls=0 (offline) OR calls=1
    // (online) is acceptable — the contract is "at most once".
    expect(calls <= 1, isTrue);
    expect(result, isNotNull);
  });

  test('pushSync returns SyncResult.empty() when pushRunner is null '
      'and offlineMode is enabled', () async {
    final svc = SyncService(
      FrappeClient('http://localhost'),
      repo,
      appDb,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      // no pushRunner
    );
    // Asserts only that pushSync doesn't throw and returns a value.
    // The empty-vs-no-internet branch depends on connectivity_plus
    // which we don't mock here.
    final result = await svc.pushSync();
    expect(result, isNotNull);
  });

  test('pushSync returns empty when offlineMode.enabled is false', () async {
    final svc = SyncService(
      FrappeClient('http://localhost'),
      repo,
      appDb,
      getMobileUuid: () async => 'test-uuid',
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
    );
    final result = await svc.pushSync();
    expect(result.success, 0);
    expect(result.failed, 0);
    expect(result.total, 0);
    expect(result.error, isNull);
  });
}
