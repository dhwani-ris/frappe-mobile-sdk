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

/// `SyncService.isOnline()` reaches for real `Connectivity()`; see
/// sync_service_filtered_page_test.dart.
class _OnlineSyncService extends SyncService {
  _OnlineSyncService(
    super.client,
    super.repository,
    super.database, {
    super.getMobileUuid,
    super.offlineMode,
    super.pageSize,
  });

  @override
  Future<bool> isOnline() async => true;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final meta = DocTypeMeta(
    name: 'Survey',
    isTable: false,
    fields: [DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title')],
  );

  /// Serves `get_list` from [rows]; records every request's filters.
  ({http.Client client, List<String?> filters}) server(
    List<Map<String, dynamic>> Function() rows,
  ) {
    final filters = <String?>[];
    final client = MockClient((req) async {
      if (req.url.path.contains('get_list')) {
        filters.add(req.url.queryParameters['filters']);
        final start = int.parse(req.url.queryParameters['limit_start'] ?? '0');
        return http.Response(
          jsonEncode({
            'message': start == 0 ? rows() : <Map<String, dynamic>>[],
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'message': []}), 200);
    });
    return (client: client, filters: filters);
  }

  Future<({SyncService sync, AppDatabase db})> harness(http.Client mock) async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.doctypeMetaDao.upsertMetaJson('Survey', jsonEncode(meta.toJson()));
    final client = FrappeClient('http://localhost', httpClient: mock);
    const mode = OfflineMode(enabled: true, isPersisted: true);
    final repo = OfflineRepository(db, offlineMode: mode, client: client);
    return (
      sync: _OnlineSyncService(
        client,
        repo,
        db,
        getMobileUuid: () async => 'u',
        offlineMode: mode,
        pageSize: 20,
      ),
      db: db,
    );
  }

  test(
    'a doctype with no rows on the server finishes its first pull',
    () async {
      final srv = server(() => []);
      final h = await harness(srv.client);
      addTearDown(h.db.close);

      expect(await h.sync.getPullPhase('Survey'), DoctypePullPhase.initial);
      final result = await h.sync.pullSync(doctype: 'Survey');

      expect(result.success, 0);
      expect(
        await h.sync.getPullPhase('Survey'),
        DoctypePullPhase.incremental,
        reason: 'an empty but fully drained doctype must not stay INITIAL',
      );
      final cursor =
          jsonDecode((await h.db.doctypeMetaDao.getLastOkCursor('Survey'))!)
              as Map<String, dynamic>;
      expect(cursor, {'modified': null, 'name': null, 'complete': true});
    },
  );

  test(
    'rows created later are still pulled after the empty first pull',
    () async {
      var rows = <Map<String, dynamic>>[];
      final srv = server(() => rows);
      final h = await harness(srv.client);
      addTearDown(h.db.close);

      await h.sync.pullSync(doctype: 'Survey');
      rows = [
        {'name': 'S-1', 'modified': '2026-11-18 10:00:00', 'title': 'first'},
      ];
      final result = await h.sync.pullSync(doctype: 'Survey');

      expect(
        result.success,
        1,
        reason: 'no watermark yet, so nothing is filtered out',
      );
      final cursor =
          jsonDecode((await h.db.doctypeMetaDao.getLastOkCursor('Survey'))!)
              as Map<String, dynamic>;
      expect(cursor, {
        'modified': '2026-11-18 10:00:00',
        'name': 'S-1',
        'complete': true,
      });
      expect(await h.sync.getPullPhase('Survey'), DoctypePullPhase.incremental);
    },
  );

  test(
    'an exact multiple of the page size completes on the empty window',
    () async {
      // 2 rows, page size 2: the first window is full, so a look-ahead fires and
      // the page is written complete:false; the look-ahead window is empty.
      final client = MockClient((req) async {
        final start = int.parse(req.url.queryParameters['limit_start'] ?? '0');
        return http.Response(
          jsonEncode({
            'message': start == 0
                ? [
                    {
                      'name': 'S-1',
                      'modified': '2026-11-18 10:00:00',
                      'title': 'a',
                    },
                    {
                      'name': 'S-2',
                      'modified': '2026-11-18 11:00:00',
                      'title': 'b',
                    },
                  ]
                : [],
          }),
          200,
        );
      });
      final db = await AppDatabase.inMemoryDatabase();
      addTearDown(db.close);
      await db.doctypeMetaDao.upsertMetaJson(
        'Survey',
        jsonEncode(meta.toJson()),
      );
      final fc = FrappeClient('http://localhost', httpClient: client);
      const mode = OfflineMode(enabled: true, isPersisted: true);
      final sync = _OnlineSyncService(
        fc,
        OfflineRepository(db, offlineMode: mode, client: fc),
        db,
        getMobileUuid: () async => 'u',
        offlineMode: mode,
        pageSize: 2,
      );

      await sync.pullSync(doctype: 'Survey');

      expect(await sync.getPullPhase('Survey'), DoctypePullPhase.incremental);
      final cursor =
          jsonDecode((await db.doctypeMetaDao.getLastOkCursor('Survey'))!)
              as Map<String, dynamic>;
      expect(cursor, {
        'modified': '2026-11-18 11:00:00',
        'name': 'S-2',
        'complete': true,
      });
    },
  );
}
