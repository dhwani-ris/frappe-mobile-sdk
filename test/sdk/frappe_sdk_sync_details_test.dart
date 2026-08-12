import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/mobile_form_name.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_engine.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_page_fetcher.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Adapts a plain-rows fake to the [ListHttpFn] page shape. `namesScanned` is
/// left null, matching the flat `get_list` path where every listed row is
/// returned.
ListHttpFn rowsFake(
  Future<List<Map<String, dynamic>>> Function(String, Map<String, Object?>) fn,
) =>
    (d, p) async => ListHttpPage(await fn(d, p));

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const doctype = 'Customer';

  // Builds an SDK with: Customer registered as a mobile form, a meta on file,
  // a COMPLETE pull cursor (so it is eligible for the pre-flight), and a
  // PullEngine whose fetcher records which doctypes it actually fetched.
  Future<({FrappeSDK sdk, List<String> fetched})> buildSdk(
    http.Client httpClient,
  ) async {
    final appDb = await AppDatabase.inMemoryDatabase();
    addTearDown(() => appDb.close());

    final meta = DocTypeMeta(
      name: doctype,
      isTable: false,
      fields: [
        DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'Name'),
      ],
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      doctype,
      jsonEncode(meta.toJson()),
    );
    // Complete (delta-ready) cursor → eligible for the /sync_details pre-flight.
    await appDb.doctypeMetaDao.setLastOkCursor(
      doctype,
      jsonEncode({
        'modified': '2026-01-01 00:00:00.000000',
        'name': 'C-1',
        'complete': true,
      }),
    );

    final sdk = FrappeSDK.forTesting(
      'http://localhost',
      appDb,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      httpClient: httpClient,
    );
    await sdk.meta.updateMobileFormDoctypesForTest([
      const MobileFormName(mobileDoctype: doctype),
    ]);

    final fetched = <String>[];
    final engine = PullEngine(
      db: appDb.rawDatabase,
      metaDao: DoctypeMetaDao(appDb.rawDatabase),
      outboxDao: OutboxDao(appDb.rawDatabase),
      pool: ConcurrencyPool(maxConcurrent: 1),
      fetcher: PullPageFetcher(
        listHttp: rowsFake((dt, _) async {
          fetched.add(dt);
          return const <Map<String, dynamic>>[];
        }),
      ),
      pageSize: 100,
      notifier: SyncStateNotifier(),
      metaResolver: (_) async => meta,
    );
    sdk.injectPullEngineForTesting(engine);
    sdk.overrideIsOnlineForTesting(() async => true);
    return (sdk: sdk, fetched: fetched);
  }

  http.Response jsonResp(Object body) => http.Response(jsonEncode(body), 200);

  test('skips pulling a doctype the manifest reports unchanged', () async {
    final built = await buildSdk(
      MockClient((req) async {
        if (req.url.path.contains('sync_details')) {
          return jsonResp({
            'message': {
              'doctypes': [
                {
                  'doctype': doctype,
                  'changed': false,
                  'count': 0,
                  'meta_bumped': false,
                },
              ],
              'delete_signals': 0,
            },
          });
        }
        return jsonResp({'message': []});
      }),
    );

    await built.sdk.runUpgradeClosurePullForTesting();

    expect(
      built.fetched,
      isEmpty,
      reason: 'unchanged doctype must be skipped — its fetcher is never hit',
    );
  });

  test('falls back to pulling when the manifest call fails', () async {
    final built = await buildSdk(
      MockClient((req) async {
        if (req.url.path.contains('sync_details')) {
          return http.Response(
            'boom',
            500,
          ); // manifest fails → null → full pull
        }
        return jsonResp({'message': []});
      }),
    );

    await built.sdk.runUpgradeClosurePullForTesting();

    expect(
      built.fetched,
      contains(doctype),
      reason: 'on manifest failure the eligible doctype must still be pulled',
    );
  });
}
