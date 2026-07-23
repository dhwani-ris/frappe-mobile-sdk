import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';

/// Regression coverage for the 2026-07-23 keyset-resume fix, HIGH-1 (verify
/// review `docs/superpowers/plans/2026-07-23-sdk-verify-review.md`).
///
/// `SyncService._pullOneInternal` is private, so these drive the real pull via
/// the public `pullSync` entrypoint. The HTTP seam is a [MockClient] injected
/// into [FrappeClient]; it emulates Frappe's `frappe.client.get_list` with the
/// two-phase AND-only KEYSET contract (parse `filters` / `order_by` /
/// `limit_page_length` off the query, filter+sort+limit an in-memory row set).
/// Because the pull applies each row through `OfflineRepository`, we persist a
/// real `DocTypeMeta` so the lazy `docs__<doctype>` table is created and the
/// cursor genuinely advances.
///
/// The load-bearing assertion in both tests reads the ON-DISK cursor JSON
/// (`getLastOkCursor`), NOT the in-memory phase — HIGH-1b specifically guards a
/// bug that a naive in-memory `!cursorComplete` check would have missed.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  DocField f(String n, String t) => DocField(fieldname: n, fieldtype: t, label: n);

  // Minimal childless meta → `_pullOneInternal` uses the flat `list` path
  // (needsFullDoc == false) and `applyServerDocument` can build the table.
  String metaJsonFor(String doctype) =>
      jsonEncode(DocTypeMeta(name: doctype, fields: [f('title', 'Data')]).toJson());

  /// Distinct, lexicographically-ordered `modified` strings so the keyset is
  /// well-defined (fixed-width `HH:MM:SS` under a fixed date prefix).
  List<Map<String, dynamic>> makeRows({
    required int count,
    required String namePrefix,
    required String datePrefix,
  }) {
    return List.generate(count, (i) {
      final hh = (i ~/ 3600).toString().padLeft(2, '0');
      final mm = ((i % 3600) ~/ 60).toString().padLeft(2, '0');
      final ss = (i % 60).toString().padLeft(2, '0');
      final name = '$namePrefix-${(i + 1).toString().padLeft(4, '0')}';
      return <String, dynamic>{
        'name': name,
        'modified': '$datePrefix $hh:$mm:$ss',
        'title': 'row-$i',
      };
    });
  }

  /// In-memory `get_list` honouring AND-only filters + order_by + limit.
  List<Map<String, dynamic>> queryRows(
    List<Map<String, dynamic>> all,
    List<List<dynamic>>? filters,
    String? order,
    int limit,
  ) {
    Iterable<Map<String, dynamic>> out = all;
    if (filters != null) {
      for (final fr in filters) {
        final field = fr[0] as String;
        final op = fr[1] as String;
        final val = fr[2] as String;
        out = out.where((r) {
          final c = (r[field] as String).compareTo(val);
          switch (op) {
            case '=':
              return c == 0;
            case '>':
              return c > 0;
            case '>=':
              return c >= 0;
            case '<':
              return c < 0;
            default:
              return true;
          }
        });
      }
    }
    final list = out.toList();
    list.sort((a, b) {
      if (order != null && order.startsWith('name')) {
        return (a['name'] as String).compareTo(b['name'] as String);
      }
      final c = (a['modified'] as String).compareTo(b['modified'] as String);
      return c != 0 ? c : (a['name'] as String).compareTo(b['name'] as String);
    });
    return list.take(limit).toList();
  }

  /// Builds a [FrappeClient] whose HTTP layer replays [serverRows] through the
  /// keyset `get_list` contract. [getListCalls] records one entry per raw page
  /// request (Phase A / Phase B each count separately).
  FrappeClient makeClient(
    List<Map<String, dynamic>> serverRows, {
    required List<Uri> getListCalls,
  }) {
    final mock = MockClient((req) async {
      if (req.url.path.contains('get_list')) {
        getListCalls.add(req.url);
        final q = req.url.queryParameters;
        final filtersRaw = q['filters'];
        final filters = filtersRaw == null
            ? null
            : (jsonDecode(filtersRaw) as List)
                  .map((e) => (e as List).cast<dynamic>())
                  .toList();
        final order = q['order_by'];
        final limit = int.tryParse(q['limit_page_length'] ?? '') ?? serverRows.length;
        final rows = queryRows(serverRows, filters, order, limit);
        return http.Response(jsonEncode({'message': rows}), 200);
      }
      // Any other endpoint the pull path may probe: benign empty envelope.
      return http.Response(jsonEncode({'message': <dynamic>[]}), 200);
    });
    return FrappeClient('http://localhost', httpClient: mock);
  }

  SyncService makeSync(AppDatabase db, FrappeClient client) {
    const mode = OfflineMode(enabled: true, isPersisted: true);
    final repo = OfflineRepository(db, offlineMode: mode, client: client);
    return SyncService(
      client,
      repo,
      db,
      getMobileUuid: () async => 'u',
      offlineMode: mode,
      // adb-reverse-style override so pullSync passes the connectivity gate.
      isOnlineOverride: () async => true,
    );
  }

  const int pageSize = 1000; // matches the hardcoded SyncService page cap

  test(
    'HIGH-1a: INITIAL drain of exactly k*pageSize rows flips cursor to '
    'complete=true (does NOT stick in RESUME)',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      const doctype = 'ExactMultipleInitial';
      await db.doctypeMetaDao.upsertMetaJson(doctype, metaJsonFor(doctype));

      // Exactly pageSize rows: page 1 is full → fires a look-ahead; page 2
      // comes back empty → the loop breaks on the empty page, bypassing the
      // in-loop `isFinalPage` promotion. Before the fix the on-disk cursor
      // stayed complete=false forever (stuck in RESUME).
      final server = makeRows(
        count: pageSize,
        namePrefix: 'D',
        datePrefix: '2026-01-01',
      );
      final calls = <Uri>[];
      final client = makeClient(server, getListCalls: calls);
      final sync = makeSync(db, client);

      expect(await sync.getPullPhase(doctype), DoctypePullPhase.initial);

      final result = await sync.pullSync(doctype: doctype);

      expect(result.total, pageSize);
      expect(result.success, pageSize);

      final raw = await db.doctypeMetaDao.getLastOkCursor(doctype);
      expect(raw, isNotNull);
      final cursor = jsonDecode(raw!) as Map<String, dynamic>;
      expect(
        cursor['complete'],
        isTrue,
        reason:
            'exact-multiple INITIAL drain must promote to complete=true via '
            'the post-loop flip; before the fix it stuck at complete=false',
      );
      expect(cursor['name'], 'D-${pageSize.toString().padLeft(4, '0')}');
      expect(
        await sync.getPullPhase(doctype),
        DoctypePullPhase.incremental,
        reason: 'a drained doctype must report INCREMENTAL, not RESUME',
      );

      await db.close();
    },
  );

  test(
    'HIGH-1b: INCREMENTAL doctype receiving exactly pageSize new rows is NOT '
    'demoted — on-disk cursor stays complete=true',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      const doctype = 'ExactMultipleIncremental';
      await db.doctypeMetaDao.upsertMetaJson(doctype, metaJsonFor(doctype));

      // Enter as INCREMENTAL (complete=true) at a historical watermark.
      const watermark = '2026-01-01 00:00:00';
      await db.doctypeMetaDao.setLastOkCursor(
        doctype,
        jsonEncode({
          'modified': watermark,
          'name': 'OLD-0000',
          'complete': true,
        }),
      );
      expect(await sync0(db).getPullPhase(doctype), DoctypePullPhase.incremental);

      // Exactly pageSize NEW rows, all modified strictly AFTER the watermark
      // (the seam Phase A block at `modified == watermark` is empty). Page 1 =
      // Phase B (full, pageSize rows) → look-ahead fired; page 2 empty → break
      // on the empty page. The only in-loop journal wrote complete=false; a
      // naive in-memory `!cursorComplete` guard (cursorComplete is still true)
      // would skip the flip and leave DISK demoted to RESUME. The fix consults
      // the on-disk mirror (`lastPersistedComplete`) and re-flips.
      final server = makeRows(
        count: pageSize,
        namePrefix: 'NEW',
        datePrefix: '2026-02-01',
      );
      final calls = <Uri>[];
      final client = makeClient(server, getListCalls: calls);
      final sync = makeSync(db, client);

      final result = await sync.pullSync(doctype: doctype);
      expect(result.total, pageSize);
      expect(result.success, pageSize);

      final raw = await db.doctypeMetaDao.getLastOkCursor(doctype);
      final cursor = jsonDecode(raw!) as Map<String, dynamic>;
      expect(
        cursor['complete'],
        isTrue,
        reason:
            'an exactly-pageSize incremental delta must NOT be demoted to '
            'RESUME on disk — the post-loop flip keys off the persisted '
            '(disk) complete flag, not the in-memory one',
      );
      expect(cursor['name'], 'NEW-${pageSize.toString().padLeft(4, '0')}');
      expect(
        await sync.getPullPhase(doctype),
        DoctypePullPhase.incremental,
      );

      await db.close();
    },
  );
}

// Tiny helper so the pre-pull phase assertion in HIGH-1b can read the DB
// without a live HTTP client.
SyncService sync0(AppDatabase db) {
  const mode = OfflineMode(enabled: true, isPersisted: true);
  final client = FrappeClient('http://localhost');
  final repo = OfflineRepository(db, offlineMode: mode, client: client);
  return SyncService(client, repo, db, getMobileUuid: () async => 'u', offlineMode: mode);
}
