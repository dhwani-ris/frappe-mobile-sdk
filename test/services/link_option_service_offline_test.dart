import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late UnifiedResolver resolver;
  late DocTypeMeta m;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
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
    for (final s in doctypeMetaExtensionsDDL()) {
      await db.execute(s);
    }
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    m = DocTypeMeta(
      name: 'Customer',
      titleField: 'customer_name',
      fields: [f('customer_name', 'Data'), f('age', 'Int')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': jsonEncode(m.toJson()),
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u1',
      'server_name': 'CUST-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'customer_name': 'ACME',
      'customer_name__norm': 'acme',
      'age': 10,
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u2',
      'sync_status': 'dirty',
      'local_modified': 2,
      'customer_name': 'Pending Inc',
      'customer_name__norm': 'pending inc',
      'age': 5,
    });
    resolver = UnifiedResolver(
      db: db,
      metaDao: DoctypeMetaDao(db),
      isOnline: () => false,
      backgroundFetch: (_, _) async {},
      metaResolver: (dt) async => m,
    );
  });

  tearDown(() async => db.close());

  LinkOptionService makeSvc() => LinkOptionService(resolver, (dt) async => m);

  group('getLinkOptions — 3-tuple filter regression (C1)', () {
    test('3-tuple [field, op, value] filter reaches resolver', () async {
      final out = await makeSvc().getLinkOptions(
        'Customer',
        filters: [
          ['age', '>=', 10],
        ],
      );
      expect(
        out.length,
        1,
        reason:
            '3-tuple filter must reach the resolver; if dropped both rows appear',
      );
      expect(out.first.name, 'CUST-1');
    });

    test('4-tuple [doctype, field, op, value] filter still works', () async {
      final out = await makeSvc().getLinkOptions(
        'Customer',
        filters: [
          ['Customer', 'age', '>=', 10],
        ],
      );
      expect(out.length, 1);
      expect(out.first.name, 'CUST-1');
    });

    test('mix of 3-tuple and 4-tuple filters are both applied', () async {
      final out = await makeSvc().getLinkOptions(
        'Customer',
        filters: [
          ['age', '>=', 10],
          ['Customer', 'age', '<=', 5],
        ],
      );
      expect(
        out,
        isEmpty,
        reason:
            'Both filters must be applied — no row satisfies age>=10 AND age<=5',
      );
    });

    test(
      'malformed filter (length 1) is skipped; valid filter applies',
      () async {
        final out = await makeSvc().getLinkOptions(
          'Customer',
          filters: [
            ['junk'],
            ['age', '>=', 10],
          ],
        );
        expect(out.length, 1);
        expect(out.first.name, 'CUST-1');
      },
    );
  });

  test('routes through resolver, returns LinkOptionEntity per row', () async {
    final svc = makeSvc();
    final out = await svc.getLinkOptionsOffline(doctype: 'Customer');
    expect(out.length, 2);
    final names = out.map((e) => e.name).toSet();
    expect(names, contains('CUST-1'));
    // Local-only row's "name" falls back to mobile_uuid.
    expect(names, contains('u2'));
    final acme = out.firstWhere((e) => e.name == 'CUST-1');
    expect(acme.label, 'ACME');
  });

  test('strips doctype prefix from 4-tuple filters', () async {
    final svc = makeSvc();
    final out = await svc.getLinkOptionsOffline(
      doctype: 'Customer',
      filters: [
        ['Customer', 'age', '>=', 10],
      ],
    );
    expect(out.length, 1);
    expect(out.first.name, 'CUST-1');
  });

  test('query parameter routes to title_field LIKE search', () async {
    final svc = makeSvc();
    final out = await svc.getLinkOptionsOffline(
      doctype: 'Customer',
      query: 'ACME',
    );
    expect(out.length, 1);
    expect(out.first.label, 'ACME');
  });
}
