import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode_notifier.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('SyncService reads mode through notifier and reflects flips', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: FrappeClient('http://localhost'),
    );
    final notifier = OfflineModeNotifier(
      const OfflineMode(enabled: false, isPersisted: true),
    );
    final sync = SyncService(
      FrappeClient('http://localhost'),
      repo,
      db,
      offlineModeNotifier: notifier,
    );

    // mode=false → pullSync short-circuits empty
    final r1 = await sync.pullSync(doctype: 'Customer');
    expect(r1.success, 0);
    expect(r1.error, isNull); // SyncResult.empty()
    expect(sync.offlineMode.enabled, isFalse);

    // flip mid-session → getter now reflects new value
    notifier.value = const OfflineMode(enabled: true, isPersisted: true);
    expect(sync.offlineMode.enabled, isTrue);
  });
}
