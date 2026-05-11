// AC3: end-to-end offline cycle integration test.
//
// Exercises the primary use-case without the full FrappeSDK init ceremony:
// real components (LocalWriter, OfflineRepository, PushEngine, PullApply,
// UnifiedResolver) wired against an in-memory SQLite database + a fake HTTP
// client.
//
// Five phases, grouped into three focused tests:
//   1. write dirty parent + children → outbox queued
//   2. push → outbox drains, doc synced (server_name assigned)
//   3. pull against synced parent → children replaced (no guard)
//   4. edit locally → parent dirty again
//   5. pull with newer server modified → C3 guard triggers:
//        • parent flagged conflict
//        • children NOT wiped
//        • UnifiedResolver reports the conflict state

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/query/query_result.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:frappe_mobile_sdk/src/sync/child_table_info.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ---------------------------------------------------------------------------
// Fake HTTP server — only the INSERT push response matters.
// Server assigns 'HS-001' with a fixed modified timestamp. All other paths
// return an empty 200 so the engine doesn't throw.
// ---------------------------------------------------------------------------
class _FakeServer extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST' &&
        request.url.path.toLowerCase().contains('household')) {
      const body =
          '{"data": {"name": "HS-001", "modified": "2026-05-11 10:00:00"}}';
      return http.StreamedResponse(
        Stream.fromIterable([body.codeUnits]),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.fromIterable(['{}'.codeUnits]),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

// ---------------------------------------------------------------------------
// Doctypes under test
// ---------------------------------------------------------------------------
final _surveyMeta = DocTypeMeta(
  name: 'Household Survey',
  isTable: false,
  fields: [
    DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title'),
    DocField(
      fieldname: 'members',
      fieldtype: 'Table',
      label: 'Members',
      options: 'Survey Member',
    ),
  ],
);

final _memberMeta = DocTypeMeta(
  name: 'Survey Member',
  isTable: true,
  fields: [
    DocField(fieldname: 'member_name', fieldtype: 'Data', label: 'Member'),
  ],
);

DocTypeMeta _metaFn(String dt) =>
    dt == 'Household Survey' ? _surveyMeta : _memberMeta;

// ---------------------------------------------------------------------------
// Convenience: query children for a given parent_uuid
// ---------------------------------------------------------------------------
Future<List<Map<String, Object?>>> _queryChildren(
  Database db,
  String parentUuid,
) => db.query(
  normalizeDoctypeTableName('Survey Member'),
  where: 'parent_uuid = ?',
  whereArgs: [parentUuid],
  orderBy: 'idx ASC',
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;
  late UnifiedResolver resolver;
  late SyncEnginePack pack;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();

    // Persist meta JSON so OfflineRepository._loadMeta finds both doctypes.
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Household Survey',
      jsonEncode(_surveyMeta.toJson()),
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Survey Member',
      jsonEncode(_memberMeta.toJson()),
    );

    final client = FrappeClient('http://localhost', httpClient: _FakeServer());

    final localWriter = LocalWriter(
      appDb.rawDatabase,
      (dt) async => _metaFn(dt),
    );

    repo = OfflineRepository(
      appDb,
      localWriter: localWriter,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: client,
      metaFetcher: (dt) async => _metaFn(dt),
    );

    // Create docs__ tables and register table_name in doctype_meta.
    await repo.ensureSchemaForClosure(
      metas: {'Household Survey': _surveyMeta, 'Survey Member': _memberMeta},
      childDoctypes: {'Survey Member'},
    );

    pack = await SyncEngineBuilder.build(
      database: appDb,
      client: client,
      metaResolver: (dt) async => _metaFn(dt),
      runPullFn: () async => const <String>{},
      applyServerDoc: (_, _) async {},
      runPullForDoctypes: (_) async {},
      concurrencyOverride: 1,
    );

    resolver = UnifiedResolver(
      db: appDb.rawDatabase,
      metaDao: DoctypeMetaDao(appDb.rawDatabase),
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: (dt) async => _metaFn(dt),
    );
  });

  tearDown(() async => appDb.close());

  // =========================================================================
  // Test 1: write offline → push → outbox drains, doc becomes synced
  // =========================================================================
  test(
    'phase 1+2: write dirty doc with children → push → outbox drains and doc synced',
    () async {
      // Phase 1 — write offline
      final uuid = await repo.saveDocument(
        doctype: 'Household Survey',
        data: {
          'title': 'Survey Alpha',
          'members': [
            {'member_name': 'Alice'},
            {'member_name': 'Bob'},
          ],
        },
      );

      // Outbox has one pending INSERT
      final outbox1 = await appDb.rawDatabase.query('outbox');
      expect(outbox1.length, 1, reason: 'one INSERT queued in outbox');
      expect(outbox1.first['operation'], 'INSERT');

      // Parent row is dirty with no server_name yet
      final parent1 = (await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Household Survey'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).first;
      expect(parent1['sync_status'], 'dirty');
      expect(parent1['server_name'], isNull);

      // Two child rows linked to the parent
      final children1 = await _queryChildren(appDb.rawDatabase, uuid);
      expect(children1.length, 2);
      expect(children1[0]['member_name'], 'Alice');
      expect(children1[1]['member_name'], 'Bob');

      // Phase 2 — push
      await pack.pushEngine.runOnce();

      // Outbox must be empty after successful push
      final outbox2 = await appDb.rawDatabase.query('outbox');
      expect(outbox2, isEmpty, reason: 'outbox drains after push');

      // Parent flips to synced with server-assigned name
      final parent2 = (await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Household Survey'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).first;
      expect(parent2['server_name'], 'HS-001');
      expect(parent2['sync_status'], 'synced');

      // UnifiedResolver sees one synced row
      final result = await resolver.resolve(
        doctype: 'Household Survey',
        page: 0,
        pageSize: 100,
      );
      expect(result.rows.length, 1);
      expect(result.rows.first['server_name'], 'HS-001');
      expect(result.rows.first['sync_status'], 'synced');
      expect(result.originBreakdown[RowOrigin.server], 1);
    },
  );

  // =========================================================================
  // Test 2: pull against a synced parent replaces children (C3 gate absent)
  // =========================================================================
  test('phase 3: pull against synced parent replaces children', () async {
    // Setup: write and push so the doc is synced
    final uuid = await repo.saveDocument(
      doctype: 'Household Survey',
      data: {
        'title': 'Survey Beta',
        'members': [
          {'member_name': 'Alice'},
          {'member_name': 'Bob'},
        ],
      },
    );
    await pack.pushEngine.runOnce();

    // Parent is synced
    final parent = (await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Household Survey'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    )).first;
    expect(parent['sync_status'], 'synced');

    // Pull: server sends HS-001 with a single new child (Charlie)
    await PullApply.applyPage(
      db: appDb.rawDatabase,
      parentMeta: _surveyMeta,
      parentTable: normalizeDoctypeTableName('Household Survey'),
      childMetasByFieldname: {
        'members': ChildTableInfo('Survey Member', _memberMeta),
      },
      rows: [
        {
          'name': 'HS-001',
          'modified': '2026-05-11 10:30:00',
          'title': 'Survey Beta (server)',
          'members': [
            {'name': 'MEMBER-SRV-1', 'member_name': 'Charlie'},
          ],
        },
      ],
    );

    // Synced parent → C3 gate is NOT triggered → children ARE replaced
    final childrenAfter = await _queryChildren(appDb.rawDatabase, uuid);
    expect(
      childrenAfter.length,
      1,
      reason: 'synced parent: pull replaces all children',
    );
    expect(childrenAfter.first['member_name'], 'Charlie');

    // Parent stays synced, title reflects server value
    final parentAfter = (await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Household Survey'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    )).first;
    expect(parentAfter['sync_status'], 'synced');

    // UnifiedResolver: one synced row
    final result = await resolver.resolve(
      doctype: 'Household Survey',
      page: 0,
      pageSize: 100,
    );
    expect(result.rows.length, 1);
    expect(result.rows.first['sync_status'], 'synced');
  });

  // =========================================================================
  // Test 3: dirty parent shields children from pull wipe (C3 invariant)
  // =========================================================================
  test(
    'C3 invariant: dirty parent shields children — pull flags conflict, children survive',
    () async {
      // Setup: write → push → now synced with modified=2026-05-11 10:00:00
      final uuid = await repo.saveDocument(
        doctype: 'Household Survey',
        data: {
          'title': 'Survey Gamma',
          'members': [
            {'member_name': 'Alice'},
          ],
        },
      );
      await pack.pushEngine.runOnce();

      // Sanity: synced after push
      final parentAfterPush = (await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Household Survey'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).first;
      expect(parentAfterPush['sync_status'], 'synced');
      expect(parentAfterPush['modified'], '2026-05-11 10:00:00');

      // Phase 4 — user edits locally; parent becomes dirty again
      await repo.saveDocument(
        doctype: 'Household Survey',
        data: {
          'mobile_uuid': uuid,
          'title': 'Survey Gamma (local edit)',
          'members': [
            {'member_name': 'Dave'},
            {'member_name': 'Eve'},
          ],
        },
      );

      // Dirty parent with two local children
      final dirtyParent = (await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Household Survey'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).first;
      expect(dirtyParent['sync_status'], 'dirty');

      final localChildren = await _queryChildren(appDb.rawDatabase, uuid);
      expect(localChildren.length, 2);
      expect(localChildren[0]['member_name'], 'Dave');
      expect(localChildren[1]['member_name'], 'Eve');

      // Phase 5 — pull with newer server modified (12:00 > stored 10:00)
      // C3 gate: dirty parent + server advanced → conflict, children skipped
      await PullApply.applyPage(
        db: appDb.rawDatabase,
        parentMeta: _surveyMeta,
        parentTable: normalizeDoctypeTableName('Household Survey'),
        childMetasByFieldname: {
          'members': ChildTableInfo('Survey Member', _memberMeta),
        },
        rows: [
          {
            'name': 'HS-001',
            'modified': '2026-05-11 12:00:00',
            'title': 'Survey Gamma (server concurrent edit)',
            'members': [
              {'name': 'MEMBER-SRV-X', 'member_name': 'Zara'},
            ],
          },
        ],
      );

      // C3: parent must be flagged conflict, NOT overwritten with server data
      final conflictParent = (await appDb.rawDatabase.query(
        normalizeDoctypeTableName('Household Survey'),
        where: 'mobile_uuid = ?',
        whereArgs: [uuid],
      )).first;
      expect(
        conflictParent['sync_status'],
        'conflict',
        reason: 'server advanced on dirty doc → conflict',
      );

      // C3: children must NOT have been wiped — Dave and Eve survive
      final survivingChildren = await _queryChildren(appDb.rawDatabase, uuid);
      expect(
        survivingChildren.length,
        2,
        reason: 'dirty parent shields children: pull must not wipe them',
      );
      expect(survivingChildren[0]['member_name'], 'Dave');
      expect(survivingChildren[1]['member_name'], 'Eve');

      // UnifiedResolver: conflict row is returned and classified as local
      final result = await resolver.resolve(
        doctype: 'Household Survey',
        page: 0,
        pageSize: 100,
      );
      expect(result.rows.length, 1);
      expect(
        result.rows.first['sync_status'],
        'conflict',
        reason: 'UnifiedResolver must surface the conflict state',
      );
      expect(
        result.originBreakdown[RowOrigin.local],
        1,
        reason: 'conflict row is local-origin (has unpushed edits)',
      );
    },
  );
}
