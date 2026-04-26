import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(appDb);
    final meta = DocTypeMeta(
      name: 'State',
      titleField: 'state_name',
      fields: [f('state_name', 'Data'), f('code', 'Data')],
    );
    // Persist meta JSON so OfflineRepository can lazy-build the schema.
    await appDb.doctypeMetaDao.upsertMetaJson('State', jsonEncode(meta.toJson()));
  });

  tearDown(() async {
    await appDb.rawDatabase.close();
  });

  test(
    'saveServerDocument writes to legacy `documents` AND `docs__state`',
    () async {
      await repo.saveServerDocument(
        doctype: 'State',
        serverId: 'STATE-MH',
        data: {
          'name': 'STATE-MH',
          'state_name': 'Maharashtra',
          'code': 'MH',
          'modified': '2026-01-01 00:00:00',
        },
      );

      // Legacy store has the row.
      final legacyDocs = await appDb.documentDao.findByDoctype('State');
      expect(legacyDocs.length, 1);

      // Per-doctype table exists and has the row.
      final perDoctype =
          await appDb.rawDatabase.query('docs__state', limit: 10);
      expect(perDoctype.length, 1);
      expect(perDoctype.first['server_name'], 'STATE-MH');
      expect(perDoctype.first['state_name'], 'Maharashtra');
      expect(perDoctype.first['code'], 'MH');
      expect(perDoctype.first['sync_status'], 'synced');
    },
  );

  test(
    'second saveServerDocument with same name UPSERTs (no duplicate)',
    () async {
      await repo.saveServerDocument(
        doctype: 'State',
        serverId: 'STATE-MH',
        data: {
          'name': 'STATE-MH',
          'state_name': 'Maharashtra',
          'modified': '2026-01-01 00:00:00',
        },
      );
      // Update with new state_name.
      await repo.saveServerDocument(
        doctype: 'State',
        serverId: 'STATE-MH',
        data: {
          'name': 'STATE-MH',
          'state_name': 'Maharashtra Updated',
          'modified': '2026-02-01 00:00:00',
        },
      );

      final rows = await appDb.rawDatabase.query('docs__state');
      expect(rows.length, 1, reason: 'UPSERT, not insert-twice');
      expect(rows.first['state_name'], 'Maharashtra Updated');
      expect(rows.first['modified'], '2026-02-01 00:00:00');
    },
  );

  test(
    'no meta persisted → per-doctype write skipped, legacy still works',
    () async {
      await repo.saveServerDocument(
        doctype: 'NoMeta',
        serverId: 'NO-1',
        data: {'name': 'NO-1', 'foo': 'bar'},
      );
      // Legacy works.
      expect((await appDb.documentDao.findByDoctype('NoMeta')).length, 1);
      // Per-doctype table NOT created (no meta available).
      final tables = await appDb.rawDatabase.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='docs__nometa'",
      );
      expect(tables, isEmpty);
    },
  );

  test(
    'two different doctypes get two separate tables',
    () async {
      final districtMeta = DocTypeMeta(
        name: 'District',
        fields: [f('district_name', 'Data')],
      );
      await appDb.doctypeMetaDao.upsertMetaJson(
        'District',
        jsonEncode(districtMeta.toJson()),
      );

      await repo.saveServerDocument(
        doctype: 'State',
        serverId: 'S1',
        data: {'name': 'S1', 'state_name': 'A'},
      );
      await repo.saveServerDocument(
        doctype: 'District',
        serverId: 'D1',
        data: {'name': 'D1', 'district_name': 'B'},
      );

      expect(
        (await appDb.rawDatabase.query('docs__state')).length,
        1,
      );
      expect(
        (await appDb.rawDatabase.query('docs__district')).length,
        1,
      );
    },
  );

  group('ensureSchemaForClosure', () {
    test('creates parent tables for every closure parent (even 0-row ones)',
        () async {
      final villageMeta = DocTypeMeta(
        name: 'Village',
        fields: [f('village_name', 'Data')],
      );
      final hamletMeta = DocTypeMeta(
        name: 'Hamlet',
        fields: [f('hamlet_name', 'Data')],
      );
      // Note: no `saveServerDocument` calls for these — table must still be
      // created so Link pickers + UnifiedResolver have something to read.
      await repo.ensureSchemaForClosure(
        metas: {'Village': villageMeta, 'Hamlet': hamletMeta},
        childDoctypes: const {},
      );
      final tables = await appDb.rawDatabase.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name IN ('docs__village','docs__hamlet') ORDER BY name",
      );
      expect(tables.map((r) => r['name']).toList(),
          ['docs__hamlet', 'docs__village']);
    });

    test('creates child tables for closure children', () async {
      final memberMeta = DocTypeMeta(
        name: 'Household Survey Family Member',
        isTable: true,
        fields: [f('member_name', 'Data'), f('age', 'Int')],
      );
      await repo.ensureSchemaForClosure(
        metas: {'Household Survey Family Member': memberMeta},
        childDoctypes: const {'Household Survey Family Member'},
      );
      final tables = await appDb.rawDatabase.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name = 'docs__household_survey_family_member'",
      );
      expect(tables, hasLength(1));
    });

    test(
      'saveServerDocument with child rows populates registered child table',
      () async {
        final hsMeta = DocTypeMeta(
          name: 'Household Survey',
          fields: [
            f('head_of_family', 'Data'),
            f('family_members', 'Table',
                options: 'Household Survey Family Member'),
          ],
        );
        final memberMeta = DocTypeMeta(
          name: 'Household Survey Family Member',
          isTable: true,
          fields: [f('member_name', 'Data'), f('age', 'Int')],
        );
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Household Survey',
          jsonEncode(hsMeta.toJson()),
        );
        await appDb.doctypeMetaDao.upsertMetaJson(
          'Household Survey Family Member',
          jsonEncode(memberMeta.toJson()),
        );
        await repo.ensureSchemaForClosure(
          metas: {
            'Household Survey': hsMeta,
            'Household Survey Family Member': memberMeta,
          },
          childDoctypes: const {'Household Survey Family Member'},
        );

        await repo.saveServerDocument(
          doctype: 'Household Survey',
          serverId: 'HS-1',
          data: {
            'name': 'HS-1',
            'modified': '2026-01-01 00:00:00',
            'head_of_family': 'Ramesh',
            'family_members': [
              {'name': 'mem-1', 'member_name': 'Sita', 'age': 32},
              {'name': 'mem-2', 'member_name': 'Mohan', 'age': 12},
            ],
          },
        );

        final children = await appDb.rawDatabase.query(
          'docs__household_survey_family_member',
          orderBy: 'idx',
        );
        expect(children.length, 2);
        expect(children[0]['member_name'], 'Sita');
        expect(children[0]['parentfield'], 'family_members');
        expect(children[0]['parent_doctype'], 'Household Survey');
        expect(children[1]['member_name'], 'Mohan');
        expect(children[1]['idx'], 1);
      },
    );
  });
}
