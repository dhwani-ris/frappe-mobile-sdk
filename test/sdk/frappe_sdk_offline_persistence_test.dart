import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('FrappeSDK offline_enabled persistence', () {
    late AppDatabase db;
    late FrappeSDK sdk;

    tearDown(() async {
      await sdk.dispose();
      await db.close();
    });

    test('readOfflineMode is fallback before any login', () async {
      db = await AppDatabase.inMemoryDatabase();
      sdk = FrappeSDK.forTesting('http://localhost', db);
      final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(mode.isPersisted, isFalse);
      expect(mode.enabled, isFalse);
    });

    test(
      'login response with offline_enabled=true persists enabled=true',
      () async {
        // Start offline=false so false→true triggers upgrade pull (not drain).
        // Upgrade pull is a no-op in tests (no mobile_form_names persisted).
        db = await AppDatabase.inMemoryDatabase();
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: false, isPersisted: true),
        );
        await sdk.persistOfflineFlagFromLoginForTesting({
          'offline_enabled': true,
          'user': 'tester@example.com',
        });
        final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
        expect(mode.enabled, isTrue);
        expect(mode.isPersisted, isTrue);
      },
    );

    test(
      'login response with offline_enabled=false persists enabled=false',
      () async {
        // Start offline=false so false→false is a no-op (no transition fires).
        db = await AppDatabase.inMemoryDatabase();
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: false, isPersisted: true),
        );
        await sdk.persistOfflineFlagFromLoginForTesting({
          'offline_enabled': false,
          'user': 'tester@example.com',
        });
        final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
        expect(mode.enabled, isFalse);
        expect(mode.isPersisted, isTrue);
      },
    );

    test(
      'login response missing offline_enabled persists enabled=false',
      () async {
        db = await AppDatabase.inMemoryDatabase();
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: false, isPersisted: true),
        );
        await sdk.persistOfflineFlagFromLoginForTesting({
          'user': 'tester@example.com',
        });
        final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
        expect(mode.enabled, isFalse);
        expect(mode.isPersisted, isTrue);
      },
    );

    test(
      'login response with offline_enabled=null persists enabled=false',
      () async {
        db = await AppDatabase.inMemoryDatabase();
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: false, isPersisted: true),
        );
        await sdk.persistOfflineFlagFromLoginForTesting({
          'offline_enabled': null,
          'user': 'tester@example.com',
        });
        final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
        expect(mode.enabled, isFalse);
        expect(mode.isPersisted, isTrue);
      },
    );
  });
}
