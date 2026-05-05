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
    'runUpgradeClosurePull is a no-op when no entry-point doctypes exist',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      );

      // No mobile_form_names persisted → closure is empty → noop.
      // Should not throw.
      await sdk.runUpgradeClosurePullForTesting();
    },
  );
}
