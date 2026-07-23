// Regression coverage for the closure-pull permission-skip guardrail in
// FrappeSDK._runUpgradeClosurePull (see lib/src/sdk/frappe_sdk.dart).
//
// The skip-set (`permission_skip_doctypes`, populated reactively from a
// prior 403) must NEVER suppress a mobile-form / manifest entry-point
// doctype — those are the surveyor's actual forms and must always be
// attempted, even if the skip-set wrongly contains one (defensive: the
// skip-set is only ever supposed to hold closure-only Link-target
// doctypes, but the guardrail must hold regardless). A non-entry
// closure-only doctype in the skip-set, by contrast, IS excluded.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/mobile_form_name.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_page_fetcher.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// Builds a FrappeSDK (forTesting) whose closure is:
  ///   'Sales Order' (mobile-form entry point) --Link:customer--> 'Customer'
  /// 'Customer' is a closure-only dependency, never an entry point.
  /// Returns the sdk plus the list that records every doctype the
  /// injected PullEngine's fetcher was actually invoked for.
  Future<({FrappeSDK sdk, List<String> fetched, AppDatabase db})>
  buildSdkWithClosure() async {
    final appDb = await AppDatabase.inMemoryDatabase();

    final salesOrderMeta = DocTypeMeta(
      name: 'Sales Order',
      fields: [f('customer', 'Link', options: 'Customer')],
    );
    final customerMeta = DocTypeMeta(
      name: 'Customer',
      fields: [f('customer_name', 'Data')],
    );

    await appDb.doctypeMetaDao.upsertMetaJson(
      'Sales Order',
      jsonEncode(salesOrderMeta.toJson()),
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Customer',
      jsonEncode(customerMeta.toJson()),
    );

    final sdk = FrappeSDK.forTesting(
      'http://localhost',
      appDb,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
    );

    // Only 'Sales Order' is a mobile-form entry point.
    await sdk.meta.updateMobileFormDoctypesForTest([
      const MobileFormName(mobileDoctype: 'Sales Order'),
    ]);

    final fetched = <String>[];
    final engine = PullEngine(
      db: appDb.rawDatabase,
      metaDao: DoctypeMetaDao(appDb.rawDatabase),
      outboxDao: OutboxDao(appDb.rawDatabase),
      pool: ConcurrencyPool(maxConcurrent: 2),
      fetcher: PullPageFetcher(
        listHttp: (doctype, params) async {
          fetched.add(doctype);
          return const <Map<String, dynamic>>[];
        },
      ),
      pageSize: 100,
      notifier: SyncStateNotifier(),
      metaResolver: (dt) async =>
          dt == 'Sales Order' ? salesOrderMeta : customerMeta,
    );

    sdk.injectPullEngineForTesting(engine);
    sdk.overrideIsOnlineForTesting(() async => true);

    return (sdk: sdk, fetched: fetched, db: appDb);
  }

  test(
    'guardrail: a manifest/entry-point doctype wrongly in the skip-set is still pulled',
    () async {
      final built = await buildSdkWithClosure();
      addTearDown(() => built.db.close());

      // Wrongly seed the skip-set with the ENTRY-POINT doctype. Production
      // code should never do this itself (the skip-set is only ever
      // populated for closure-dependency pulls), but the closure filter must
      // be defensive regardless of how the skip-set got populated. Stamp it
      // NOW so it is an ACTIVE skip (within the revisit TTL).
      await SdkMetaDao(built.db.rawDatabase).addSkippedDoctype(
        'Sales Order',
        deniedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );

      await built.sdk.runUpgradeClosurePullForTesting();

      expect(
        built.fetched,
        contains('Sales Order'),
        reason:
            'entry-point doctypes must always be attempted, even if '
            'present in the permission-skip set',
      );
    },
  );

  test(
    'a non-entry closure-only doctype in the skip-set is excluded from the pull',
    () async {
      final built = await buildSdkWithClosure();
      addTearDown(() => built.db.close());

      // 'Customer' is a Link-target dependency, never an entry point —
      // this is exactly the kind of doctype the skip-set exists to prune.
      // Stamp it NOW so it is an ACTIVE skip (within the revisit TTL).
      await SdkMetaDao(built.db.rawDatabase).addSkippedDoctype(
        'Customer',
        deniedAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );

      await built.sdk.runUpgradeClosurePullForTesting();

      expect(
        built.fetched,
        contains('Sales Order'),
        reason: 'the entry point itself is unaffected',
      );
      expect(
        built.fetched,
        isNot(contains('Customer')),
        reason:
            'a skipped non-entry closure dependency must be excluded '
            'from the pull',
      );
    },
  );

  test(
    'baseline: empty skip-set pulls every closure doctype',
    () async {
      final built = await buildSdkWithClosure();
      addTearDown(() => built.db.close());

      await built.sdk.runUpgradeClosurePullForTesting();

      expect(built.fetched, containsAll(['Sales Order', 'Customer']));
    },
  );
}
