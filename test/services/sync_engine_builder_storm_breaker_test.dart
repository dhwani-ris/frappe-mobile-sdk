// Fix 2 — "storm-breaker" auth-event coverage, exercised through the REAL
// wiring built by `SyncEngineBuilder.build` (the `onPermissionDeniedRound`
// closure lives there). A `MockClient` injected into `FrappeClient` returns
// a genuine HTTP 403 for chosen doctypes, so the whole path runs end-to-end:
//   RestHelper → AuthException(403) → PullEngine round aggregation →
//   metaDao.protectedPullDoctypes() → auth-event vs skip-with-expiry.
//
// Contract under test (D4 / AC#2 of the closure-denylist plan):
//  a. A round where a PROTECTED doctype (isMobileForm=1, or one that has
//     synced rows) 403s ⇒ ZERO skips recorded for the WHOLE round + the
//     notifier's lastError.code == 'auth'.
//  b. A round where ONLY a NON-protected framework doctype 403s ⇒ that
//     doctype IS persisted as a skip with a denied_at stamp, and no auth
//     error is raised. A protected 403 anywhere in the round shields every
//     other denied doctype from being skipped.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
import 'package:frappe_mobile_sdk/src/models/closure_result.dart';
import 'package:frappe_mobile_sdk/src/models/dep_graph.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t) => DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// Builds the full engine pack over an in-memory DB.
  ///   [doctypes] maps doctype name → isMobileForm (protected iff true).
  ///   [forbidden] is the set of doctypes the mock server 403s on; everything
  ///   else returns an empty 200 page.
  /// Each seeded meta has ONLY plain Data fields (no Table children) so the
  /// closure pull uses `frappe.client.get_list` (the `?doctype=` GET the mock
  /// keys off), not `listFullDocs`.
  Future<({SyncEnginePack pack, AppDatabase db})> buildPack({
    required Map<String, bool> doctypes,
    required Set<String> forbidden,
  }) async {
    final appDb = await AppDatabase.inMemoryDatabase();
    final metas = <String, DocTypeMeta>{};
    for (final entry in doctypes.entries) {
      final meta = DocTypeMeta(name: entry.key, fields: [f('title', 'Data')]);
      metas[entry.key] = meta;
      await appDb.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: entry.key,
          isMobileForm: entry.value,
          metaJson: jsonEncode(meta.toJson()),
        ),
      );
    }

    final mock = MockClient((req) async {
      final dt = req.url.queryParameters['doctype'];
      if (dt != null && forbidden.contains(dt)) {
        return http.Response(
          jsonEncode({'exc_type': 'PermissionError'}),
          403,
        );
      }
      return http.Response(jsonEncode({'message': <dynamic>[]}), 200);
    });

    final pack = await SyncEngineBuilder.build(
      database: appDb,
      client: FrappeClient('http://localhost', httpClient: mock),
      metaResolver: (dt) async => metas[dt]!,
      runPullFn: () async => const <String>{},
      applyServerDoc: (_, _) async {},
      runPullForDoctypes: (_) async {},
      concurrencyOverride: 2,
    );
    return (pack: pack, db: appDb);
  }

  ClosureResult closureOf(List<String> dts) => ClosureResult(
        doctypes: dts,
        graph: {
          for (final d in dts)
            d: DepGraph(
              doctype: d,
              tier: 0,
              outgoing: const [],
              incoming: const [],
            ),
        },
        childDoctypes: const {},
        warnings: const [],
      );

  Future<Set<String>> activeSkips(AppDatabase db) => SdkMetaDao(
        db.rawDatabase,
      ).readActiveSkippedDoctypes(
        nowMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );

  test(
    '2a. a PROTECTED doctype 403 ⇒ ZERO skips for the round + lastError.code == auth',
    () async {
      // Member is a mobile-form entry point ⇒ protected.
      final built = await buildPack(
        doctypes: {'Member': true},
        forbidden: {'Member'},
      );
      addTearDown(() => built.db.close());

      await built.pack.pullEngine.run(
        closureOf(['Member']),
        allowedDoctypes: {'Member'},
      );

      expect(
        await activeSkips(built.db),
        isEmpty,
        reason: 'a protected 403 is an auth event — no skip may be recorded',
      );
      final err = built.pack.notifier.value.lastError;
      expect(err, isNotNull);
      expect(
        err!.code,
        'auth',
        reason: 'a previously-readable doctype 403 surfaces as an auth error',
      );
    },
  );

  test(
    '2b(i). a NON-protected framework doctype 403 ⇒ skip persisted with a denied_at stamp',
    () async {
      // Country: closure-only Link target, never a mobile form, no synced
      // rows ⇒ NOT protected.
      final built = await buildPack(
        doctypes: {'Country': false},
        forbidden: {'Country'},
      );
      addTearDown(() => built.db.close());

      final before = DateTime.now().toUtc().millisecondsSinceEpoch;
      await built.pack.pullEngine.run(
        closureOf(['Country']),
        allowedDoctypes: {'Country'},
      );

      expect(
        await activeSkips(built.db),
        {'Country'},
        reason: 'an unprotected framework 403 is recorded as a skip-with-expiry',
      );
      // denied_at was stamped (roughly) now, not left at 0/legacy.
      final rows = await built.db.rawDatabase.query('permission_skip_doctypes');
      expect(rows, hasLength(1));
      expect(rows.first['doctype'], 'Country');
      expect((rows.first['denied_at_ms'] as int) >= before, isTrue);
      // No protected doctype was denied ⇒ no auth error.
      expect(built.pack.notifier.value.lastError, isNull);
    },
  );

  test(
    '2b(ii). a protected 403 shields EVERY denied doctype in the round from skips',
    () async {
      // Member (protected) AND Country (unprotected) both 403 in the same
      // round. The protected hit converts the whole round into an auth event
      // ⇒ Country must NOT be skipped either.
      final built = await buildPack(
        doctypes: {'Member': true, 'Country': false},
        forbidden: {'Member', 'Country'},
      );
      addTearDown(() => built.db.close());

      await built.pack.pullEngine.run(
        closureOf(['Member', 'Country']),
        allowedDoctypes: {'Member', 'Country'},
      );

      expect(
        await activeSkips(built.db),
        isEmpty,
        reason:
            'a protected 403 anywhere in the round records ZERO skips — the '
            'unprotected Country 403 is shielded too',
      );
      expect(built.pack.notifier.value.lastError?.code, 'auth');
    },
  );
}
