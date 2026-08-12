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

/// `SyncService.isOnline()` reaches for real `Connectivity()`, which has no
/// injection seam. Overriding it is the only way to drive `_pullOneInternal`'s
/// paging loop under test.
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

  // A `Table` field makes `_doctypeHasChildTables` true, which is what routes
  // the pull through `listFullDocsPage` — the endpoint whose per-doc permission
  // gate silently drops names.
  final meta = DocTypeMeta(
    name: 'Customer',
    isTable: false,
    fields: [
      DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'Name'),
      DocField(
        fieldname: 'addresses',
        fieldtype: 'Table',
        label: 'Addresses',
        options: 'Customer Address',
      ),
    ],
  );

  /// Serves `get_list` name pages and `get_docs_with_children` doc batches from
  /// [namesByStart] / [docsByName], recording every `limit_start` requested.
  ({http.Client client, List<int> starts}) mockServer({
    required Map<int, List<String>> namesByStart,
    required Set<String> allowed,
  }) {
    final starts = <int>[];
    final client = MockClient((req) async {
      if (req.url.path.contains('get_list')) {
        final start = int.parse(req.url.queryParameters['limit_start'] ?? '0');
        starts.add(start);
        final names = namesByStart[start] ?? const <String>[];
        return http.Response(
          jsonEncode({
            'message': [
              for (final n in names) {'name': n},
            ],
          }),
          200,
        );
      }
      if (req.url.path.contains('get_docs_with_children')) {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final requested = (body['names'] as List).cast<String>();
        return http.Response(
          jsonEncode({
            'message': [
              // The gate drops anything not in `allowed` — exactly what
              // bulkGetWithChildren's docstring describes.
              for (final n in requested)
                if (allowed.contains(n))
                  {
                    'name': n,
                    'modified':
                        '2026-01-${n.split('-').last.padLeft(2, '0')}'
                        ' 00:00:00',
                    'customer_name': 'Name $n',
                  },
            ],
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'message': []}), 200);
    });
    return (client: client, starts: starts);
  }

  Future<({SyncService sync, AppDatabase db})> harness(
    http.Client mock, {
    int pageSize = 2,
  }) async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.doctypeMetaDao.upsertMetaJson(
      'Customer',
      jsonEncode(meta.toJson()),
    );
    final client = FrappeClient('http://localhost', httpClient: mock);
    const mode = OfflineMode(enabled: true, isPersisted: true);
    // `applyServerPage` calls `_ensurePerDoctypeTable` itself, so the mirror
    // table is created lazily on the first applied page.
    final repo = OfflineRepository(db, offlineMode: mode, client: client);
    return (
      sync: _OnlineSyncService(
        client,
        repo,
        db,
        getMobileUuid: () async => 'u',
        offlineMode: mode,
        pageSize: pageSize,
      ),
      db: db,
    );
  }

  Future<List<String>> pulledNames(AppDatabase db) async {
    final rows = await db.rawDatabase.query(
      'docs__customer',
      orderBy: 'server_name',
    );
    return rows.map((r) => r['server_name'] as String).toList();
  }

  test('a FULLY permission-filtered window does not end the drain', () async {
    // Window at limit_start=2 resolves to zero docs. Before the fix the loop
    // hit `page.isEmpty` and broke, stalling the drain at offset 2 on every
    // subsequent sync — C-5 was never pulled.
    final srv = mockServer(
      namesByStart: {
        0: ['C-1', 'C-2'],
        2: ['C-3', 'C-4'],
        4: ['C-5'],
      },
      allowed: {'C-1', 'C-2', 'C-5'},
    );
    final h = await harness(srv.client);
    addTearDown(h.db.close);

    final result = await h.sync.pullSync(doctype: 'Customer');

    expect(
      srv.starts,
      containsAllInOrder([0, 2, 4]),
      reason: 'the filtered window must be skipped, not treated as the end',
    );
    expect(await pulledNames(h.db), ['C-1', 'C-2', 'C-5']);
    expect(result.success, 3);
  });

  test(
    'a PARTIALLY filtered full window is not mistaken for a short final page',
    () async {
      // The subtler half of the same bug: the look-ahead keyed off docs
      // RETURNED, so dropping even one name made a full window look short —
      // no look-ahead fired, the page was declared final, and the cursor
      // flipped to complete:true with every later page unfetched.
      final srv = mockServer(
        namesByStart: {
          0: ['C-1', 'C-2'],
          2: ['C-3'],
        },
        allowed: {'C-1', 'C-3'},
      );
      final h = await harness(srv.client);
      addTearDown(h.db.close);

      await h.sync.pullSync(doctype: 'Customer');

      expect(
        srv.starts,
        containsAllInOrder([0, 2]),
        reason:
            'scanned == pageSize means the window was full even though '
            'only one doc came back',
      );
      expect(await pulledNames(h.db), ['C-1', 'C-3']);
    },
  );

  test(
    'a genuinely drained doctype still completes on the short page',
    () async {
      final srv = mockServer(
        namesByStart: {
          0: ['C-1', 'C-2'],
          2: ['C-3'],
        },
        allowed: {'C-1', 'C-2', 'C-3'},
      );
      final h = await harness(srv.client);
      addTearDown(h.db.close);

      await h.sync.pullSync(doctype: 'Customer');

      expect(await pulledNames(h.db), ['C-1', 'C-2', 'C-3']);
      final cursor = await h.db.doctypeMetaDao.getLastOkCursor('Customer');
      expect(cursor, isNotNull);
      final parsed = jsonDecode(cursor!) as Map<String, dynamic>;
      expect(
        parsed['complete'],
        isTrue,
        reason: 'the short final window still flips the doctype to incremental',
      );
    },
  );

  test('an all-filtered short final window still promotes the cursor rather '
      'than sticking in RESUME forever', () async {
    final srv = mockServer(
      namesByStart: {
        0: ['C-1', 'C-2'],
        2: ['C-3'],
      },
      allowed: {'C-1', 'C-2'},
    );
    final h = await harness(srv.client);
    addTearDown(h.db.close);

    await h.sync.pullSync(doctype: 'Customer');

    expect(await pulledNames(h.db), ['C-1', 'C-2']);
    final parsed =
        jsonDecode((await h.db.doctypeMetaDao.getLastOkCursor('Customer'))!)
            as Map<String, dynamic>;
    expect(parsed['complete'], isTrue);
  });

  test('an empty first window is genuine end-of-stream', () async {
    final srv = mockServer(namesByStart: const {}, allowed: const {});
    final h = await harness(srv.client);
    addTearDown(h.db.close);

    final result = await h.sync.pullSync(doctype: 'Customer');

    expect(srv.starts, [0], reason: 'must not keep probing further windows');
    expect(result.total, 0);
    // No page was applied, so the mirror table was never even created.
    final tables = await h.db.rawDatabase.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='docs__customer'",
    );
    expect(tables, isEmpty);
  });
}
