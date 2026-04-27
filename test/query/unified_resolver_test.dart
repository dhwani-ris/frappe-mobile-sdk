import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/query_result.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DoctypeMetaDao metaDao;

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
    final m = DocTypeMeta(
      name: 'Customer',
      titleField: 'customer_name',
      fields: [f('customer_name', 'Data'), f('age', 'Int')],
    );
    for (final s in buildParentSchemaDDL(m, tableName: 'docs__customer')) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Customer',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__customer',
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u1',
      'server_name': 'CUST-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'customer_name': 'ACME',
      'age': 10,
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u2',
      'sync_status': 'dirty',
      'local_modified': 2,
      'customer_name': 'NEW',
      'age': 5,
    });
    await db.insert('docs__customer', {
      'mobile_uuid': 'u3',
      'sync_status': 'failed',
      'local_modified': 3,
      'customer_name': 'Bad',
      'age': 0,
    });
    metaDao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  UnifiedResolver makeResolver({
    bool online = false,
    Future<void> Function(String, Map<String, Object?>)? bgFetcher,
  }) =>
      UnifiedResolver(
        db: db,
        metaDao: metaDao,
        isOnline: () => online,
        backgroundFetch: bgFetcher ?? (_, __) async {},
        metaResolver: (dt) async => DocTypeMeta(
          name: dt,
          titleField: 'customer_name',
          fields: [f('customer_name', 'Data'), f('age', 'Int')],
        ),
      );

  test('returns synced + dirty, excludes failed by default', () async {
    final r = makeResolver();
    final result = await r.resolve(
      doctype: 'Customer',
      filters: const [],
      page: 0,
      pageSize: 50,
    );
    final uuids = result.rows.map((r) => r['mobile_uuid']).toSet();
    expect(uuids, containsAll(<Object?>{'u1', 'u2'}));
    expect(uuids, isNot(contains('u3')));
    expect(result.originBreakdown[RowOrigin.local], 1);
    expect(result.originBreakdown[RowOrigin.server], 1);
  });

  test('includeFailed=true includes failed rows', () async {
    final r = makeResolver();
    final result = await r.resolve(
      doctype: 'Customer',
      filters: const [],
      page: 0,
      pageSize: 50,
      includeFailed: true,
    );
    final uuids = result.rows.map((r) => r['mobile_uuid']).toSet();
    expect(uuids, contains('u3'));
  });

  test('applies filter via FilterParser', () async {
    final r = makeResolver();
    final result = await r.resolve(
      doctype: 'Customer',
      filters: [
        ['age', '>=', 10],
      ],
      page: 0,
      pageSize: 50,
    );
    expect(result.rows.length, 1);
    expect(result.rows.first['customer_name'], 'ACME');
  });

  test('pagination hasMore true when pageSize fills', () async {
    final r = makeResolver();
    final result = await r.resolve(
      doctype: 'Customer',
      filters: const [],
      page: 0,
      pageSize: 2,
      includeFailed: true,
    );
    expect(result.rows.length, 2);
    expect(result.hasMore, isTrue);
    final page2 = await r.resolve(
      doctype: 'Customer',
      filters: const [],
      page: 1,
      pageSize: 2,
      includeFailed: true,
    );
    expect(page2.rows.length, 1);
    expect(page2.hasMore, isFalse);
  });

  test('online → background fetcher fires once per unique key', () async {
    var calls = 0;
    final r = makeResolver(
      online: true,
      bgFetcher: (doctype, params) async {
        calls++;
      },
    );
    await Future.wait([
      r.resolve(
        doctype: 'Customer',
        filters: [
          ['age', '>', 0],
        ],
        page: 0,
        pageSize: 10,
      ),
      r.resolve(
        doctype: 'Customer',
        filters: [
          ['age', '>', 0],
        ],
        page: 0,
        pageSize: 10,
      ),
    ]);
    // Wait for the background fetch to settle.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 1, reason: 'dedup should collapse to one background fetch');
  });

  test('different requests fire different background fetches', () async {
    var calls = 0;
    final r = makeResolver(
      online: true,
      bgFetcher: (doctype, params) async {
        calls++;
      },
    );
    await r.resolve(
      doctype: 'Customer',
      filters: [
        ['age', '>', 0],
      ],
      page: 0,
      pageSize: 10,
    );
    // Wait so the first bg fetch finishes and the dedup key clears.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await r.resolve(
      doctype: 'Customer',
      filters: [
        ['age', '>', 100],
      ],
      page: 0,
      pageSize: 10,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 2);
  });

  test('offline → no background fetch attempted', () async {
    var calls = 0;
    final r = makeResolver(
      online: false,
      bgFetcher: (doctype, params) async {
        calls++;
      },
    );
    await r.resolve(
      doctype: 'Customer',
      filters: const [],
      page: 0,
      pageSize: 10,
    );
    expect(calls, 0);
  });

  test('background fetch failure does not break resolve()', () async {
    final r = makeResolver(
      online: true,
      bgFetcher: (doctype, params) async {
        throw StateError('upstream is down');
      },
    );
    final result = await r.resolve(
      doctype: 'Customer',
      filters: const [],
      page: 0,
      pageSize: 10,
    );
    expect(result.rows, isNotEmpty);
    // Let the bg future resolve so the test runner doesn't see an
    // unhandled async error.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}
