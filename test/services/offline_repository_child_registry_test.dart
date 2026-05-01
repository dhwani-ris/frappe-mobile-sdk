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
  });

  tearDown(() async {
    await appDb.rawDatabase.close();
  });

  test('ensureSchemaForClosure persists is_parent_with_children for parents '
      'with Table fields', () async {
    final parent = DocTypeMeta(
      name: 'Sales Order',
      titleField: 'name',
      fields: [
        f('customer', 'Link', options: 'Customer'),
        f('items', 'Table', options: 'Sales Order Item'),
      ],
    );
    final child = DocTypeMeta(
      name: 'Sales Order Item',
      titleField: 'item_code',
      fields: [f('item_code', 'Data')],
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Sales Order',
      jsonEncode(parent.toJson()),
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Sales Order Item',
      jsonEncode(child.toJson()),
    );

    await repo.ensureSchemaForClosure(
      metas: {'Sales Order': parent, 'Sales Order Item': child},
      childDoctypes: {'Sales Order Item'},
    );

    final rows = await appDb.rawDatabase.rawQuery(
      'SELECT doctype FROM doctype_meta WHERE is_parent_with_children = 1',
    );
    final names = rows.map((r) => r['doctype'] as String).toSet();
    expect(names, contains('Sales Order'));
    expect(names, isNot(contains('Sales Order Item')));
  });

  test(
    'doctypesWithChildren merges in-memory keys with persisted DB rows',
    () async {
      // Persist a doctype that the in-memory cache has NOT seen this process
      // (simulates cold start).
      final cold = DocTypeMeta(
        name: 'Cold Parent',
        titleField: 'name',
        fields: [f('items', 'Table', options: 'Cold Child')],
      );
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Cold Parent',
        jsonEncode(cold.toJson()),
      );
      await appDb.doctypeMetaDao.setIsParentWithChildren('Cold Parent', true);

      // Register a different doctype this process — populates _childMetasByParent
      // AND the persisted flag (the flag write happens inside
      // ensureSchemaForClosure).
      final hot = DocTypeMeta(
        name: 'Hot Parent',
        titleField: 'name',
        fields: [f('lines', 'Table', options: 'Hot Child')],
      );
      final hotChild = DocTypeMeta(
        name: 'Hot Child',
        titleField: 'name',
        fields: [f('name', 'Data')],
      );
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Hot Parent',
        jsonEncode(hot.toJson()),
      );
      await appDb.doctypeMetaDao.upsertMetaJson(
        'Hot Child',
        jsonEncode(hotChild.toJson()),
      );
      await repo.ensureSchemaForClosure(
        metas: {'Hot Parent': hot, 'Hot Child': hotChild},
        childDoctypes: {'Hot Child'},
      );

      final got = await repo.doctypesWithChildren();
      expect(got, containsAll(<String>{'Cold Parent', 'Hot Parent'}));
    },
  );
}
