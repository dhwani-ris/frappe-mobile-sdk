// Covers UnifiedResolver._translateParentFilters / _resolveParentUuid —
// the child-table query path that maps Frappe's `parent` filter
// (= server_name of parent) to the local `parent_uuid` column
// (= mobile_uuid of parent).
//
// Two cases:
//   1. Caller already has the parent's mobile_uuid (offline case) →
//      direct parent_uuid match works.
//   2. Caller has the parent's server_name (post-sync case) →
//      resolver looks up the parent table and translates to mobile_uuid.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/unified_resolver.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField _f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

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
    // Parent table (Order).
    final parentMeta = DocTypeMeta(
      name: 'Order',
      fields: [_f('title', 'Data')],
    );
    for (final s in buildParentSchemaDDL(
      parentMeta,
      tableName: 'docs__order',
    )) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Order',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__order',
    });
    // One synced parent (has server_name) + one offline parent (no server_name).
    await db.insert('docs__order', {
      'mobile_uuid': 'order-1-uuid',
      'server_name': 'ORDER-1',
      'sync_status': 'synced',
      'local_modified': 1,
      'title': 'O-1',
    });
    await db.insert('docs__order', {
      'mobile_uuid': 'order-2-uuid',
      'sync_status': 'dirty',
      'local_modified': 1,
      'title': 'O-2',
    });

    // Child table.
    final childMeta = DocTypeMeta(
      name: 'Order Item',
      isTable: true,
      fields: [_f('qty', 'Int')],
    );
    for (final s in buildChildSchemaDDL(
      childMeta,
      tableName: 'docs__order_item',
    )) {
      await db.execute(s);
    }
    await db.insert('doctype_meta', {
      'doctype': 'Order Item',
      'metaJson': '{}',
      'isMobileForm': 0,
      'table_name': 'docs__order_item',
    });
    // Children of both parents.
    await db.insert('docs__order_item', {
      'mobile_uuid': 'item-1',
      'parent_uuid': 'order-1-uuid',
      'parent_doctype': 'Order',
      'parentfield': 'items',
      'idx': 1,
      'qty': 5,
    });
    await db.insert('docs__order_item', {
      'mobile_uuid': 'item-2',
      'parent_uuid': 'order-2-uuid',
      'parent_doctype': 'Order',
      'parentfield': 'items',
      'idx': 1,
      'qty': 7,
    });

    metaDao = DoctypeMetaDao(db);
  });

  tearDown(() async => db.close());

  UnifiedResolver makeResolver() => UnifiedResolver(
    db: db,
    metaDao: metaDao,
    isOnline: () => false,
    backgroundFetch: (_, _) async {},
    metaResolver: (dt) async {
      if (dt == 'Order') {
        return DocTypeMeta(name: 'Order', fields: [_f('title', 'Data')]);
      }
      return DocTypeMeta(
        name: 'Order Item',
        isTable: true,
        fields: [_f('qty', 'Int')],
      );
    },
  );

  test('child-table query: parent = <mobile_uuid> matches directly', () async {
    final resolver = makeResolver();
    final result = await resolver.resolve(
      doctype: 'Order Item',
      filters: [
        ['parent', '=', 'order-2-uuid'],
      ],
    );
    expect(result.rows, hasLength(1));
    expect(result.rows.single['qty'], 7);
    expect(result.rows.single['parent_uuid'], 'order-2-uuid');
  });

  test(
    'child-table query: parent = <server_name> resolves through parent table',
    () async {
      final resolver = makeResolver();
      final result = await resolver.resolve(
        doctype: 'Order Item',
        filters: [
          ['parent', '=', 'ORDER-1'],
        ],
      );
      expect(result.rows, hasLength(1));
      expect(result.rows.single['qty'], 5);
      expect(result.rows.single['parent_uuid'], 'order-1-uuid');
    },
  );

  test('child-table query: unknown parent value yields zero rows', () async {
    final resolver = makeResolver();
    final result = await resolver.resolve(
      doctype: 'Order Item',
      filters: [
        ['parent', '=', 'NO-SUCH-PARENT'],
      ],
    );
    expect(result.rows, isEmpty);
  });

  test(
    'child-table query: non-= operator maps column without resolving',
    () async {
      final resolver = makeResolver();
      // `IS NOT NULL` is not a value lookup; resolver should map the column
      // name to parent_uuid without trying to resolve a server_name.
      final result = await resolver.resolve(
        doctype: 'Order Item',
        filters: [
          ['parent', 'is not', null],
        ],
      );
      expect(result.rows, hasLength(2));
    },
  );

  test('non-parent filters pass through untouched on child tables', () async {
    final resolver = makeResolver();
    final result = await resolver.resolve(
      doctype: 'Order Item',
      filters: [
        ['qty', '>=', 6],
      ],
    );
    expect(result.rows, hasLength(1));
    expect(result.rows.single['qty'], 7);
  });

  test('parent-doctype query is unaffected by parent translation', () async {
    final resolver = makeResolver();
    final result = await resolver.resolve(
      doctype: 'Order',
      filters: [
        ['title', '=', 'O-1'],
      ],
    );
    expect(result.rows, hasLength(1));
    expect(result.rows.single['mobile_uuid'], 'order-1-uuid');
  });
}
