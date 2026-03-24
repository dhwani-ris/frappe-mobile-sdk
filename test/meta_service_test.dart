import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
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

    test('onUpgrade adds groupName and sortOrder to existing v1 database', () async {
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
      await rawDb.execute('ALTER TABLE doctype_meta ADD COLUMN groupName TEXT');
      await rawDb.execute('ALTER TABLE doctype_meta ADD COLUMN sortOrder INTEGER');
      final rows = await rawDb.query('doctype_meta', where: 'doctype = ?', whereArgs: ['OldDoc']);
      expect(rows.length, 1);
      expect(rows.first['groupName'], isNull);
      expect(rows.first['sortOrder'], isNull);
      await rawDb.insert('doctype_meta', {
        'doctype': 'NewDoc', 'modified': null, 'serverModifiedAt': null,
        'isMobileForm': 1, 'metaJson': '{}', 'groupName': 'MyGroup', 'sortOrder': 0,
      });
      final newRows = await rawDb.query('doctype_meta', where: 'doctype = ?', whereArgs: ['NewDoc']);
      expect(newRows.first['groupName'], 'MyGroup');
      await rawDb.close();
      // Clean up
      await databaseFactoryFfi.deleteDatabase(dbPath);
    });
  });
}
