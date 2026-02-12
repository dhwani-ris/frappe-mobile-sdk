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
}
