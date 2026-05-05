import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'forTesting threads the same notifier into sync, repo, and resolver',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      );

      // All three services see enabled=false.
      expect(sdk.sync.offlineMode.enabled, isFalse);
      expect(sdk.repository.offlineMode.enabled, isFalse);
      expect(sdk.resolver.offlineMode.enabled, isFalse);

      // SDK-level helper flips the shared notifier.
      sdk.flipOfflineModeForTesting(
        const OfflineMode(enabled: true, isPersisted: true),
      );

      // Every service sees the new value via the same notifier.
      expect(sdk.sync.offlineMode.enabled, isTrue);
      expect(sdk.repository.offlineMode.enabled, isTrue);
      expect(sdk.resolver.offlineMode.enabled, isTrue);
      expect(sdk.offlineModeForTesting.enabled, isTrue);
    },
  );
}
