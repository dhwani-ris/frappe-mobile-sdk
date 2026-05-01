import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('FrappeSDK offline_enabled persistence', () {
    late AppDatabase db;
    late FrappeSDK sdk;

    setUp(() async {
      db = await AppDatabase.inMemoryDatabase();
      sdk = FrappeSDK.forTesting('http://localhost', db);
    });

    tearDown(() async {
      await sdk.dispose();
      await db.close();
    });

    test('readOfflineMode is fallback before any login', () async {
      final mode = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(mode.isPersisted, isFalse);
      expect(mode.enabled, isFalse);
    });

    test(
      'login response with offline_enabled=true persists enabled=true',
      () async {
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
