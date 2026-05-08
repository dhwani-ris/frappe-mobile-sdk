import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode_notifier.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('OfflineRepository reads mode through notifier', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final notifier = OfflineModeNotifier(
      const OfflineMode(enabled: true, isPersisted: true),
    );
    final repo = OfflineRepository(
      db,
      offlineModeNotifier: notifier,
      client: FrappeClient('http://localhost'),
    );

    // Initial state from notifier flows through.
    expect(repo.offlineMode.enabled, isTrue);

    // Flip the notifier → getter reflects immediately (live read,
    // not a captured snapshot).
    notifier.value = const OfflineMode(enabled: false, isPersisted: true);
    expect(repo.offlineMode.enabled, isFalse);

    // And back.
    notifier.value = const OfflineMode(enabled: true, isPersisted: false);
    expect(repo.offlineMode.enabled, isTrue);
    expect(repo.offlineMode.isPersisted, isFalse);
  });
}
