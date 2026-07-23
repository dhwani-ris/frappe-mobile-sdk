// Fix 4 / SWF-00533 — the awaitable public closure-pull entrypoint the app
// bootstrap screen drives, plus the mutex guarantee that awaiting the
// login-fired pull and a concurrent `runClosurePull()` never start two
// overlapping `PullEngine.run` bodies (a double-pull ~2x first-sync time).
//
// Convention (see frappe_sdk_initial_sync_defer_test.dart): the literal
// login()/verifyLoginOtp()/_fetchUserInfoAndApply() paths bind
// FlutterSecureStorage + real HTTP + ConnectivityWatcher.production, none of
// which have test doubles here, so we exercise the EFFECT via FrappeSDK.
// forTesting + injection seams and pin the wiring with a source guard.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
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

DocTypeMeta _customerMeta() => DocTypeMeta(
      name: 'Customer',
      isTable: false,
      fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
    );

/// Registers Customer as a mobile form + persists its meta + creates the
/// docs__customer mirror table, so `_runUpgradeClosurePull` builds a
/// non-empty pullable closure and PullEngine.run has somewhere to write.
Future<FrappeSDK> _sdkWithCustomer(AppDatabase appDb) async {
  await appDb.doctypeMetaDao.upsertMetaJson(
    'Customer',
    jsonEncode(_customerMeta().toJson()),
  );
  for (final s in buildParentSchemaDDL(
    _customerMeta(),
    tableName: 'docs__customer',
  )) {
    await appDb.rawDatabase.execute(s);
  }
  final sdk = FrappeSDK.forTesting(
    'http://localhost',
    appDb,
    offlineMode: const OfflineMode(enabled: true, isPersisted: true),
  );
  await sdk.meta.updateMobileFormDoctypesForTest([
    const MobileFormName(mobileDoctype: 'Customer'),
  ]);
  sdk.overrideIsOnlineForTesting(() async => true);
  return sdk;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('runClosurePull returns the SIG-2 deferred set (active outbox push)',
      () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    addTearDown(() => appDb.close());
    final sdk = await _sdkWithCustomer(appDb);

    // A pending outbox row makes PullEngine defer Customer instead of pulling.
    final outboxDao = OutboxDao(appDb.rawDatabase);
    await outboxDao.insertPending(
      doctype: 'Customer',
      mobileUuid: 'u-1',
      operation: OutboxOperation.insert,
    );

    sdk.injectPullEngineForTesting(PullEngine(
      db: appDb.rawDatabase,
      metaDao: DoctypeMetaDao(appDb.rawDatabase),
      outboxDao: outboxDao,
      pool: ConcurrencyPool(maxConcurrent: 1),
      fetcher: PullPageFetcher(
        listHttp: (_, __) async => const <Map<String, dynamic>>[],
      ),
      pageSize: 100,
      notifier: SyncStateNotifier(),
      metaResolver: (_) async => _customerMeta(),
    ));

    final deferred = await sdk.runClosurePull();
    expect(
      deferred,
      contains('Customer'),
      reason:
          'runClosurePull delegates to _runUpgradeClosurePull — the SIG-2 '
          'deferred set must propagate back to the awaiting bootstrap',
    );
  });

  test('runClosurePull drives a real pull: applies rows + completes the cursor',
      () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    addTearDown(() => appDb.close());
    final sdk = await _sdkWithCustomer(appDb);

    var calls = 0;
    sdk.injectPullEngineForTesting(PullEngine(
      db: appDb.rawDatabase,
      metaDao: DoctypeMetaDao(appDb.rawDatabase),
      outboxDao: OutboxDao(appDb.rawDatabase),
      pool: ConcurrencyPool(maxConcurrent: 1),
      fetcher: PullPageFetcher(
        listHttp: (doctype, params) async {
          calls++;
          return calls == 1
              ? [
                  {
                    'name': 'C-1',
                    'modified': '2026-01-01 00:00:00',
                    'customer_name': 'Acme',
                  },
                ]
              : const <Map<String, dynamic>>[];
        },
      ),
      pageSize: 500,
      notifier: SyncStateNotifier(),
      metaResolver: (_) async => _customerMeta(),
    ));

    await sdk.runClosurePull();

    expect(
      (await appDb.rawDatabase.query('docs__customer')).length,
      1,
      reason: 'runClosurePull must actually pull + apply Member-style rows',
    );
    final cursor =
        await DoctypeMetaDao(appDb.rawDatabase).getLastOkCursor('Customer');
    expect(cursor, isNotNull);
    expect((jsonDecode(cursor!) as Map<String, dynamic>)['complete'], isTrue);
  });

  test(
    'two concurrent runClosurePull() SERIALISE via the SyncMutex — no two '
    'PullEngine.run bodies overlap (no double-pull)',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      addTearDown(() => appDb.close());
      final sdk = await _sdkWithCustomer(appDb);

      // The fetcher body straddles an async gap: if two run() bodies were
      // live at once, `active` would reach 2. The mutex around PullEngine.run
      // must keep it at 1.
      var active = 0;
      var maxActive = 0;
      sdk.injectPullEngineForTesting(PullEngine(
        db: appDb.rawDatabase,
        metaDao: DoctypeMetaDao(appDb.rawDatabase),
        outboxDao: OutboxDao(appDb.rawDatabase),
        pool: ConcurrencyPool(maxConcurrent: 1),
        fetcher: PullPageFetcher(
          listHttp: (_, __) async {
            active++;
            if (active > maxActive) maxActive = active;
            await Future<void>.delayed(const Duration(milliseconds: 10));
            active--;
            return const <Map<String, dynamic>>[];
          },
        ),
        pageSize: 500,
        notifier: SyncStateNotifier(),
        metaResolver: (_) async => _customerMeta(),
      ));

      // Fire both without awaiting between — they race into the shared mutex.
      final a = sdk.runClosurePull();
      final b = sdk.runClosurePull();
      await Future.wait([a, b]);

      expect(
        maxActive,
        1,
        reason:
            'awaiting the login-fired pull + a concurrent runClosurePull must '
            'serialise through SyncService.protect — never two overlapping '
            'PullEngine.run bodies (that double-pull ~2x first-sync time)',
      );
    },
  );

  // ── Source guard: the three login paths TRACK the fired sync ──────────────
  // Real login()/verifyLoginOtp()/_fetchUserInfoAndApply() bind network +
  // secure storage (no test doubles), so pin the wiring statically: each must
  // route through _fireInitialSyncTracked() (which assigns _initialSyncFuture
  // + unawaits it) rather than the old bare `unawaited(_initialMetaAndDataSync())`
  // that left the bootstrap unable to await the in-flight pull → double-pull.
  test('login / verifyLoginOtp / _fetchUserInfoAndApply track _initialSyncFuture',
      () {
    final source = File('lib/src/sdk/frappe_sdk.dart').readAsStringSync();

    // (i) _fireInitialSyncTracked assigns + unawaits the fired sync.
    final start = source.indexOf('void _fireInitialSyncTracked() {');
    expect(start, greaterThanOrEqualTo(0),
        reason: '_fireInitialSyncTracked missing — has the tracker been removed?');
    final body = source.substring(start, start + 400);
    expect(body, contains('_initialSyncFuture = _initialMetaAndDataSync()'));
    expect(body, contains('unawaited(_initialSyncFuture!)'));

    // (ii) All THREE login entry points call the tracker.
    final calls = '_fireInitialSyncTracked();'.allMatches(source).length;
    expect(calls, 3,
        reason:
            'login, verifyLoginOtp and _fetchUserInfoAndApply must each fire '
            'the TRACKED sync (found $calls call sites, expected 3)');

    // (iii) REGRESSION: the old untracked statement must be gone — a bare
    // `unawaited(_initialMetaAndDataSync());` fires a pull the bootstrap can
    // never await, so the bootstrap starts a SECOND concurrent one.
    expect(
      source,
      isNot(contains('unawaited(_initialMetaAndDataSync());')),
      reason:
          'a login path fires an UNTRACKED initial sync — the bootstrap cannot '
          'observe it and will double-pull under the mutex',
    );
  });
}
