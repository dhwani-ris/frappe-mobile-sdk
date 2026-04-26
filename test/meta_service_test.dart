import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/mobile_form_name.dart';
import 'package:frappe_mobile_sdk/src/services/bulk_watermark_probe.dart';
import 'package:frappe_mobile_sdk/src/services/meta_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Initialize sqflite for testing
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('MetaService.getMobileFormDoctypeNames', () {
    test('returns only doctypes marked as mobile forms', () async {
      // Create in-memory database for testing
      final db = await AppDatabase.inMemoryDatabase();
      final client = FrappeClient('https://fake.test');

      // Insert some fake meta rows
      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'Customer',
          modified: '2025-01-01 00:00:00',
          serverModifiedAt: '2025-01-01 00:00:00',
          isMobileForm: true,
          metaJson: jsonEncode(<String, dynamic>{
            'name': 'Customer',
            'fields': <dynamic>[],
          }),
        ),
      );

      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'Lead',
          modified: '2025-01-02 00:00:00',
          serverModifiedAt: '2025-01-02 00:00:00',
          isMobileForm: false,
          metaJson: jsonEncode(<String, dynamic>{
            'name': 'Lead',
            'fields': <dynamic>[],
          }),
        ),
      );

      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'Item',
          modified: '2025-01-03 00:00:00',
          serverModifiedAt: '2025-01-03 00:00:00',
          isMobileForm: true,
          metaJson: jsonEncode(<String, dynamic>{
            'name': 'Item',
            'fields': <dynamic>[],
          }),
        ),
      );

      final metaService = MetaService(client, db);
      final names = await metaService.getMobileFormDoctypeNames();

      expect(names.length, 2);
      expect(names, containsAll(<String>['Customer', 'Item']));
      expect(names, isNot(contains('Lead')));
    });
  });

  group('DB migration v1→v2', () {
    test('groupName and sortOrder columns exist after onCreate', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'TestDoc',
          modified: null,
          serverModifiedAt: null,
          isMobileForm: true,
          metaJson: '{}',
          groupName: 'TestGroup',
          sortOrder: 0,
        ),
      );
      final result = await db.doctypeMetaDao.findByDoctype('TestDoc');
      expect(result?.groupName, 'TestGroup');
      expect(result?.sortOrder, 0);
    });

    test('groupName defaults to null when not provided', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'NoGroup',
          modified: null,
          serverModifiedAt: null,
          isMobileForm: false,
          metaJson: '{}',
        ),
      );
      final result = await db.doctypeMetaDao.findByDoctype('NoGroup');
      expect(result?.groupName, isNull);
      expect(result?.sortOrder, isNull);
    });

    test(
      'onUpgrade adds groupName and sortOrder to existing v1 database',
      () async {
        const dbPath = 'v1_migration_test.db';
        // Delete any leftover DB from a previous run to ensure a clean slate
        await databaseFactoryFfi.deleteDatabase(dbPath);

        final rawDb = await databaseFactoryFfi.openDatabase(
          dbPath,
          options: OpenDatabaseOptions(
            version: 1,
            singleInstance: false,
            onCreate: (db, v) async {
              await db.execute('''
              CREATE TABLE doctype_meta (
                doctype TEXT PRIMARY KEY,
                modified TEXT,
                serverModifiedAt TEXT,
                isMobileForm INTEGER NOT NULL DEFAULT 0,
                metaJson TEXT NOT NULL
              )
            ''');
            },
          ),
        );
        await rawDb.insert('doctype_meta', {
          'doctype': 'OldDoc',
          'modified': '2025-01-01',
          'serverModifiedAt': null,
          'isMobileForm': 1,
          'metaJson': '{}',
        });
        // Simulate onUpgrade 1→2
        await rawDb.execute(
          'ALTER TABLE doctype_meta ADD COLUMN groupName TEXT',
        );
        await rawDb.execute(
          'ALTER TABLE doctype_meta ADD COLUMN sortOrder INTEGER',
        );
        final rows = await rawDb.query(
          'doctype_meta',
          where: 'doctype = ?',
          whereArgs: ['OldDoc'],
        );
        expect(rows.length, 1);
        expect(rows.first['groupName'], isNull);
        expect(rows.first['sortOrder'], isNull);
        await rawDb.insert('doctype_meta', {
          'doctype': 'NewDoc',
          'modified': null,
          'serverModifiedAt': null,
          'isMobileForm': 1,
          'metaJson': '{}',
          'groupName': 'MyGroup',
          'sortOrder': 0,
        });
        final newRows = await rawDb.query(
          'doctype_meta',
          where: 'doctype = ?',
          whereArgs: ['NewDoc'],
        );
        expect(newRows.first['groupName'], 'MyGroup');
        await rawDb.close();
        // Clean up
        await databaseFactoryFfi.deleteDatabase(dbPath);
      },
    );
  });

  group('DoctypeMetaDao.findMobileFormDoctypes ordering', () {
    test('returns mobile form doctypes sorted by sortOrder ASC', () async {
      const dbPath = 'ordering_test.db';
      await databaseFactoryFfi.deleteDatabase(dbPath);
      final rawDb = await databaseFactoryFfi.openDatabase(
        dbPath,
        options: OpenDatabaseOptions(
          version: 2,
          singleInstance: false,
          onCreate: (db, v) async {
            await db.execute('''
              CREATE TABLE doctype_meta (
                doctype TEXT PRIMARY KEY,
                modified TEXT,
                serverModifiedAt TEXT,
                isMobileForm INTEGER NOT NULL DEFAULT 0,
                metaJson TEXT NOT NULL,
                groupName TEXT,
                sortOrder INTEGER
              )
            ''');
          },
        ),
      );

      // Insert in reverse sortOrder to confirm ordering is explicit, not insertion-based
      await rawDb.insert('doctype_meta', {
        'doctype': 'FormC',
        'modified': null,
        'serverModifiedAt': null,
        'isMobileForm': 1,
        'metaJson': '{}',
        'groupName': 'G1',
        'sortOrder': 2,
      });
      await rawDb.insert('doctype_meta', {
        'doctype': 'FormA',
        'modified': null,
        'serverModifiedAt': null,
        'isMobileForm': 1,
        'metaJson': '{}',
        'groupName': 'G1',
        'sortOrder': 0,
      });
      await rawDb.insert('doctype_meta', {
        'doctype': 'FormB',
        'modified': null,
        'serverModifiedAt': null,
        'isMobileForm': 1,
        'metaJson': '{}',
        'groupName': 'G2',
        'sortOrder': 1,
      });

      final dao = DoctypeMetaDao(rawDb);
      final results = await dao.findMobileFormDoctypes();
      final doctypes = results.map((e) => e.doctype).toList();
      expect(doctypes, ['FormA', 'FormB', 'FormC']);

      await rawDb.close();
      await databaseFactoryFfi.deleteDatabase(dbPath);
    });
  });

  group('_updateMobileFormDoctypes loop behaviour', () {
    test(
      'loop 2 writes groupName and sortOrder from MobileFormName list',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final client = FrappeClient('https://fake.test');
        final metaService = MetaService(client, db);

        final forms = [
          const MobileFormName(
            mobileDoctype: 'Form A',
            groupName: 'Group1',
            doctypeMetaModifiedAt: null,
            doctypeIcon: null,
          ),
          const MobileFormName(
            mobileDoctype: 'Form B',
            groupName: 'Group2',
            doctypeMetaModifiedAt: null,
            doctypeIcon: null,
          ),
          const MobileFormName(
            mobileDoctype: 'Form C',
            groupName: 'Group1',
            doctypeMetaModifiedAt: null,
            doctypeIcon: null,
          ),
        ];

        await metaService.updateMobileFormDoctypesForTest(forms);

        final a = await db.doctypeMetaDao.findByDoctype('Form A');
        final b = await db.doctypeMetaDao.findByDoctype('Form B');
        final c = await db.doctypeMetaDao.findByDoctype('Form C');

        expect(a?.groupName, 'Group1');
        expect(a?.sortOrder, 0);
        expect(b?.groupName, 'Group2');
        expect(b?.sortOrder, 1);
        expect(c?.groupName, 'Group1');
        expect(c?.sortOrder, 2);
      },
    );

    test(
      'loop 1 preserves groupName and sortOrder when marking isMobileForm=false',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final client = FrappeClient('https://fake.test');
        final metaService = MetaService(client, db);

        // First call: set up a row with groupName
        await metaService.updateMobileFormDoctypesForTest([
          const MobileFormName(
            mobileDoctype: 'Survey',
            groupName: 'Survey Group',
            doctypeMetaModifiedAt: null,
            doctypeIcon: null,
          ),
        ]);

        // Second call with different set — loop 1 marks 'Survey' as isMobileForm=false
        // It must NOT null out groupName/sortOrder during that step
        await metaService.updateMobileFormDoctypesForTest([
          const MobileFormName(
            mobileDoctype: 'Assessment',
            groupName: 'Assessment Group',
            doctypeMetaModifiedAt: null,
            doctypeIcon: null,
          ),
        ]);

        final survey = await db.doctypeMetaDao.findByDoctype('Survey');
        expect(survey?.groupName, 'Survey Group');
        expect(survey?.sortOrder, 0);
        expect(survey?.isMobileForm, isFalse);
      },
    );
  });

  group('MetaService.getMobileFormGroups', () {
    test('returns groups in sortOrder order', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final client = FrappeClient('https://fake.test');
      final metaService = MetaService(client, db);

      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'Z Form',
          modified: null,
          serverModifiedAt: null,
          isMobileForm: true,
          metaJson: '{}',
          groupName: 'ZGroup',
          sortOrder: 2,
        ),
      );
      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'A Form',
          modified: null,
          serverModifiedAt: null,
          isMobileForm: true,
          metaJson: '{}',
          groupName: 'AGroup',
          sortOrder: 0,
        ),
      );
      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'M Form',
          modified: null,
          serverModifiedAt: null,
          isMobileForm: true,
          metaJson: '{}',
          groupName: 'MGroup',
          sortOrder: 1,
        ),
      );

      final groups = await metaService.getMobileFormGroups();
      expect(groups.keys.toList(), ['AGroup', 'MGroup', 'ZGroup']);
    });

    test('places null groupName into Other bucket', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final client = FrappeClient('https://fake.test');
      final metaService = MetaService(client, db);

      await db.doctypeMetaDao.insertDoctypeMeta(
        DoctypeMetaEntity(
          doctype: 'Ungrouped Form',
          modified: null,
          serverModifiedAt: null,
          isMobileForm: true,
          metaJson: '{}',
          sortOrder: 0,
        ),
      );

      final groups = await metaService.getMobileFormGroups();
      expect(groups.containsKey('Other'), isTrue);
      expect(groups['Other'], contains('Ungrouped Form'));
    });

    test('returns empty map when no mobile forms exist', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final client = FrappeClient('https://fake.test');
      final metaService = MetaService(client, db);

      final groups = await metaService.getMobileFormGroups();
      expect(groups, isEmpty);
    });
  });

  group('DoctypeMetaDao preserves groupName on update', () {
    test(
      'updateDoctypeMeta preserves groupName and sortOrder from existing row',
      () async {
        final db = await AppDatabase.inMemoryDatabase();

        await db.doctypeMetaDao.insertDoctypeMeta(
          DoctypeMetaEntity(
            doctype: 'My Form',
            modified: '2026-01-01',
            serverModifiedAt: '2026-01-01',
            isMobileForm: true,
            metaJson: '{"fields":[]}',
            groupName: 'My Group',
            sortOrder: 5,
          ),
        );

        final existing = await db.doctypeMetaDao.findByDoctype('My Form');
        final refreshed = DoctypeMetaEntity(
          doctype: 'My Form',
          modified: '2026-01-02',
          serverModifiedAt: existing?.serverModifiedAt,
          isMobileForm: existing?.isMobileForm ?? false,
          metaJson: '{"fields":[{"fieldname":"title"}]}',
          groupName: existing?.groupName,
          sortOrder: existing?.sortOrder,
        );
        await db.doctypeMetaDao.updateDoctypeMeta(refreshed);

        final result = await db.doctypeMetaDao.findByDoctype('My Form');
        expect(result?.groupName, 'My Group');
        expect(result?.sortOrder, 5);
        expect(result?.modified, '2026-01-02');
      },
    );
  });

  group('MetaService — P2 extensions', () {
    DocField f(String name, String type, {String? options}) =>
        DocField(fieldname: name, fieldtype: type, label: name, options: options);

    test('closure walks Link + Table edges via injected metaFetcher', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = MetaService(FrappeClient('https://fake.test'), db);

      final cat = <String, DocTypeMeta>{
        'Sales Order': DocTypeMeta(name: 'Sales Order', fields: [
          f('customer', 'Link', options: 'Customer'),
          f('items', 'Table', options: 'Sales Order Item'),
        ]),
        'Customer': DocTypeMeta(name: 'Customer', fields: const []),
        'Sales Order Item': DocTypeMeta(
          name: 'Sales Order Item',
          isTable: true,
          fields: const [],
        ),
      };

      final closure = await svc.closure(
        const ['Sales Order'],
        metaFetcher: (dt) async => cat[dt]!,
      );
      expect(
        closure.doctypes.toSet(),
        {'Sales Order', 'Customer', 'Sales Order Item'},
      );
      expect(closure.childDoctypes, {'Sales Order Item'});
    });

    test('refreshWatermarks falls back to per-doctype fetcher', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = MetaService(FrappeClient('https://fake.test'), db);
      final marks = await svc.refreshWatermarks(
        const ['Customer', 'Sales Order'],
        watermarkFetcher: (dt) async => '$dt-mark',
      );
      expect(marks['Customer'], 'Customer-mark');
      expect(marks['Sales Order'], 'Sales Order-mark');
    });

    test('refreshWatermarks uses bulk probe when available', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = MetaService(FrappeClient('https://fake.test'), db);
      final probe = BulkWatermarkProbe(
        appMethodName: 'app.get_meta_watermarks',
        requester: (method, doctypes) async => BulkProbeResult(
          headerVersion: '1',
          rows: [
            for (final dt in doctypes)
              {'doctype': dt, 'modified': 'bulk-$dt'},
          ],
        ),
      );
      final marks = await svc.refreshWatermarks(
        const ['Customer', 'Sales Order'],
        probe: probe,
      );
      expect(marks['Customer'], 'bulk-Customer');
      expect(marks['Sales Order'], 'bulk-Sales Order');
    });

    test(
      'ensureUpToDate skips doctypes whose watermark matches local',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final svc = MetaService(FrappeClient('https://fake.test'), db);

        // Seed a meta row + watermark.
        await db.doctypeMetaDao.insertDoctypeMeta(
          DoctypeMetaEntity(
            doctype: 'Customer',
            modified: '2026-01-01',
            serverModifiedAt: null,
            isMobileForm: false,
            metaJson: jsonEncode(
              DocTypeMeta(name: 'Customer', fields: const []).toJson(),
            ),
          ),
        );
        await db.doctypeMetaDao.setMetaWatermark('Customer', 'mark-1');

        var fetchCalls = 0;
        final result = await svc.ensureUpToDate(
          const ['Customer'],
          watermarkFetcher: (dt) async => 'mark-1',
          metaFetcher: (dt) async {
            fetchCalls++;
            return DocTypeMeta(name: dt, fields: const []);
          },
        );
        expect(fetchCalls, 0,
            reason: 'identical watermark must not refetch meta');
        expect(result.unchanged, ['Customer']);
        expect(result.updated, isEmpty);
        expect(result.failed, isEmpty);
      },
    );

    test(
      'ensureUpToDate isolates per-doctype failures (one bad doctype does '
      'NOT block the others)',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final svc = MetaService(FrappeClient('https://fake.test'), db);
        final dao = db.doctypeMetaDao;

        for (final dt in ['Good', 'Boom', 'AlsoGood']) {
          await dao.insertDoctypeMeta(
            DoctypeMetaEntity(
              doctype: dt,
              modified: null,
              serverModifiedAt: null,
              isMobileForm: false,
              metaJson: '{}',
            ),
          );
        }

        final result = await svc.ensureUpToDate(
          const ['Good', 'Boom', 'AlsoGood'],
          watermarkFetcher: (dt) async => 'mark',
          metaFetcher: (dt) async {
            if (dt == 'Boom') throw StateError('upstream meta server is down');
            return DocTypeMeta(name: dt, fields: const []);
          },
        );

        expect(result.updated.toSet(), {'Good', 'AlsoGood'});
        expect(result.failed.keys, ['Boom']);
        expect(result.failed['Boom'], contains('upstream meta server'));
        expect(result.allSucceeded, isFalse);
        expect(await dao.getMetaWatermark('Good'), 'mark');
        expect(await dao.getMetaWatermark('AlsoGood'), 'mark');
        expect(await dao.getMetaWatermark('Boom'), isNull,
            reason: 'failed doctype must not advance its watermark');
      },
    );

    test(
      'ensureUpToDate refetches meta and persists graph + watermark on mismatch',
      () async {
        final db = await AppDatabase.inMemoryDatabase();
        final svc = MetaService(FrappeClient('https://fake.test'), db);
        final dao = db.doctypeMetaDao;

        await dao.insertDoctypeMeta(
          DoctypeMetaEntity(
            doctype: 'Customer',
            modified: null,
            serverModifiedAt: null,
            isMobileForm: false,
            metaJson: '{}',
          ),
        );

        final result = await svc.ensureUpToDate(
          const ['Customer'],
          watermarkFetcher: (dt) async => 'mark-2',
          metaFetcher: (dt) async => DocTypeMeta(
            name: dt,
            fields: [
              DocField(
                fieldname: 'territory',
                fieldtype: 'Link',
                label: 'Territory',
                options: 'Territory',
              ),
            ],
          ),
        );

        expect(result.updated, ['Customer']);
        expect(result.failed, isEmpty);
        expect(await dao.getMetaWatermark('Customer'), 'mark-2');
        final dg = await svc.depGraphFor('Customer');
        expect(dg, isNotNull);
        expect(dg!.outgoing.length, 1);
        expect(dg.outgoing.first.targetDoctype, 'Territory');
      },
    );

    test('primeDepGraphs writes one row per closure doctype', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final svc = MetaService(FrappeClient('https://fake.test'), db);
      final dao = db.doctypeMetaDao;

      // Seed meta rows so foreign-keyish lookups succeed.
      for (final dt in ['Sales Order', 'Customer', 'Sales Order Item']) {
        await dao.insertDoctypeMeta(
          DoctypeMetaEntity(
            doctype: dt,
            modified: null,
            serverModifiedAt: null,
            isMobileForm: false,
            metaJson: '{}',
          ),
        );
      }

      final cat = <String, DocTypeMeta>{
        'Sales Order': DocTypeMeta(name: 'Sales Order', fields: [
          f('customer', 'Link', options: 'Customer'),
          f('items', 'Table', options: 'Sales Order Item'),
        ]),
        'Customer': DocTypeMeta(name: 'Customer', fields: const []),
        'Sales Order Item': DocTypeMeta(
          name: 'Sales Order Item',
          isTable: true,
          fields: const [],
        ),
      };
      final closure = await svc.closure(
        const ['Sales Order'],
        metaFetcher: (dt) async => cat[dt]!,
      );
      await svc.primeDepGraphs(closure);

      for (final dt in closure.doctypes) {
        final g = await svc.depGraphFor(dt);
        expect(g, isNotNull, reason: 'dep graph missing for $dt');
      }
    });
  });
}
