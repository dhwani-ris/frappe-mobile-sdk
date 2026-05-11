import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/mobile_form_name.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_page_fetcher.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
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
      // Should not throw and returns an empty set.
      final result = await sdk.runUpgradeClosurePullForTesting();
      expect(result, isEmpty);
    },
  );

  // =========================================================================
  // Wiring test: active push deferred set propagates through
  // _runUpgradeClosurePull → PullEngine.run() → returned Set<String>
  // =========================================================================
  test(
    'runUpgradeClosurePull returns deferred doctype when active push is in outbox',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      addTearDown(() => appDb.close());

      const doctype = 'Customer';
      final customerMeta = DocTypeMeta(
        name: doctype,
        isTable: false,
        fields: [
          DocField(
            fieldname: 'customer_name',
            fieldtype: 'Data',
            label: 'Name',
          ),
        ],
      );

      // Persist meta JSON so MetaService.getMeta reads from DB (no HTTP call).
      await appDb.doctypeMetaDao.upsertMetaJson(
        doctype,
        jsonEncode(customerMeta.toJson()),
      );

      final sdk = FrappeSDK.forTesting(
        'http://localhost',
        appDb,
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      );

      // Register Customer as a mobile form so getMobileFormDoctypeNames
      // returns it and the closure includes it.
      await sdk.meta.updateMobileFormDoctypesForTest([
        const MobileFormName(mobileDoctype: doctype),
      ]);

      // Insert a pending outbox row → PullEngine will see hasActivePushFor
      // return true and defer Customer instead of pulling it.
      final outboxDao = OutboxDao(appDb.rawDatabase);
      await outboxDao.insertPending(
        doctype: doctype,
        mobileUuid: 'test-uuid-1',
        operation: OutboxOperation.insert,
      );

      // Build a PullEngine with a fake fetcher (listHttp never called for a
      // deferred doctype, but must be non-null for construction).
      final engine = PullEngine(
        db: appDb.rawDatabase,
        metaDao: DoctypeMetaDao(appDb.rawDatabase),
        outboxDao: outboxDao,
        pool: ConcurrencyPool(maxConcurrent: 1),
        fetcher: PullPageFetcher(
          listHttp: (_, _) async => const <Map<String, dynamic>>[],
        ),
        pageSize: 100,
        notifier: SyncStateNotifier(),
        metaResolver: (_) async => customerMeta,
      );

      // Inject the engine and bypass the connectivity check so
      // _runUpgradeClosurePull reaches PullEngine.run().
      sdk.injectPullEngineForTesting(engine);
      sdk.overrideIsOnlineForTesting(() async => true);

      final deferred = await sdk.runUpgradeClosurePullForTesting();

      expect(
        deferred,
        contains(doctype),
        reason:
            'active outbox push defers the doctype; deferred set must '
            'propagate from PullEngine.run() back through _runUpgradeClosurePull',
      );
    },
  );
}
