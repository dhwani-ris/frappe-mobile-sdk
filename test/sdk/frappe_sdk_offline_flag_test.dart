import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/offline_transition_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late FrappeSDK sdk;

  setUp(() async {
    db = await AppDatabase.inMemoryDatabase();
  });

  tearDown(() async {
    await sdk.dispose();
  });

  group('_applyOfflineFlag', () {
    test('unpersisted + incoming=false → persists, no transition', () async {
      sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: false),
      );
      await sdk.persistOfflineFlagFromLoginForTesting({
        'offline_enabled': false,
      });
      final persisted = await SdkMetaDao(db.rawDatabase).readOfflineMode();
      expect(persisted.enabled, isFalse);
      expect(persisted.isPersisted, isTrue);
      expect(sdk.offlineModeForTesting.enabled, isFalse);
    });

    test(
      'unpersisted + incoming=true → persists + flips notifier + upgrades',
      () async {
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: false, isPersisted: false),
        );
        await sdk.persistOfflineFlagFromLoginForTesting({
          'offline_enabled': true,
        });
        // Flag persisted.
        final persisted = await SdkMetaDao(db.rawDatabase).readOfflineMode();
        expect(persisted.enabled, isTrue);
        expect(persisted.isPersisted, isTrue);
        // Notifier flipped — every service sees enabled=true now.
        expect(sdk.offlineModeForTesting.enabled, isTrue);
        expect(sdk.sync.offlineMode.enabled, isTrue);
        expect(sdk.repository.offlineMode.enabled, isTrue);
        expect(sdk.resolver.offlineMode.enabled, isTrue);
        // Upgrade pull was kicked off (unawaited). With no mobile_form_names
        // it's a no-op; the test just asserts no crash.
      },
    );

    test('enabled=false → enabled=true → upgrade fires', () async {
      sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      );
      await sdk.persistOfflineFlagFromLoginForTesting({
        'offline_enabled': true,
      });
      expect(sdk.offlineModeForTesting.enabled, isTrue);
    });

    test(
      'enabled=true → enabled=false → downgrade emits transition states',
      () async {
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        );

        final emitted = <Type>[];
        final sub = sdk.offlineTransition.stream.listen((s) {
          emitted.add(s.runtimeType);
        });

        await sdk.persistOfflineFlagFromLoginForTesting({
          'offline_enabled': false,
        });

        // Give the unawaited transition a tick to run.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Empty residue → drain succeeds → wipe → completed.
        expect(emitted, contains(TransitionDraining));
        expect(emitted, contains(TransitionWipingTables));
        expect(emitted, contains(TransitionCompleted));

        expect(sdk.offlineModeForTesting.enabled, isFalse);
        await sub.cancel();
      },
    );

    test('enabled=true → enabled=true → no transition', () async {
      sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      );

      final emitted = <Type>[];
      final sub = sdk.offlineTransition.stream.listen((s) {
        emitted.add(s.runtimeType);
      });

      await sdk.persistOfflineFlagFromLoginForTesting({
        'offline_enabled': true,
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(emitted, isEmpty);
      expect(sdk.offlineModeForTesting.enabled, isTrue);
      await sub.cancel();
    });

    test('enabled=false → enabled=false → no transition', () async {
      sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      );

      final emitted = <Type>[];
      final sub = sdk.offlineTransition.stream.listen((s) {
        emitted.add(s.runtimeType);
      });

      await sdk.persistOfflineFlagFromLoginForTesting({
        'offline_enabled': false,
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(emitted, isEmpty);
      expect(sdk.offlineModeForTesting.enabled, isFalse);
      await sub.cancel();
    });

    // Tolerance cases — pin the contract that the login response can be
    // shaped by an older mobile_control server (missing field, null,
    // non-boolean) without crashing the SDK or accidentally enabling
    // offline mode. The production predicate is
    // `response['offline_enabled'] == true`, which yields false for any
    // non-`true` value. Section 7.1 of the migration spec.

    test(
      'field absent (stale mobile_control) → stays disabled, no throw',
      () async {
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: false, isPersisted: false),
        );
        await sdk.persistOfflineFlagFromLoginForTesting(<String, dynamic>{});
        final persisted = await SdkMetaDao(db.rawDatabase).readOfflineMode();
        expect(persisted.enabled, isFalse);
        expect(persisted.isPersisted, isTrue);
        expect(sdk.offlineModeForTesting.enabled, isFalse);
      },
    );

    test('field present but null → stays disabled, no throw', () async {
      sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: false),
      );
      await sdk.persistOfflineFlagFromLoginForTesting({
        'offline_enabled': null,
      });
      expect(sdk.offlineModeForTesting.enabled, isFalse);
    });

    test(
      'field is string "true" → stays disabled (no truthiness coercion)',
      () async {
        sdk = FrappeSDK.forTesting(
          'http://localhost',
          db,
          offlineMode: const OfflineMode(enabled: false, isPersisted: false),
        );
        await sdk.persistOfflineFlagFromLoginForTesting({
          'offline_enabled': 'true',
        });
        expect(sdk.offlineModeForTesting.enabled, isFalse);
      },
    );

    test('field is integer 1 → stays disabled (no integer coercion)', () async {
      sdk = FrappeSDK.forTesting(
        'http://localhost',
        db,
        offlineMode: const OfflineMode(enabled: false, isPersisted: false),
      );
      await sdk.persistOfflineFlagFromLoginForTesting({'offline_enabled': 1});
      expect(sdk.offlineModeForTesting.enabled, isFalse);
    });
  });
}
