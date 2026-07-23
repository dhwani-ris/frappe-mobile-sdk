// Fix 3 / AC#2 — SQL reserved-word column identifiers must be quoted in the
// generated DDL so a doctype like Frappe's "User Document Type" (whose fields
// are literally `read`/`write`/`create`/`delete`/`submit`/`cancel`/`amend`)
// creates cleanly, and its columns are readable/writable afterwards.
//
// Pre-fix the DDL emitted bare `read TEXT`, `order TEXT`, … which SQLite
// rejects with a syntax error at CREATE TABLE (the reserved words are illegal
// in column-def position unquoted). The first test proves those words really
// are reserved; the rest prove the fix's quoting round-trips through both DDL
// and the DML read path (FilterParser).

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField f(String n) => DocField(fieldname: n, fieldtype: 'Data', label: n);

/// Representative SQL reserved words that appear as real doctype field names
/// (User Document Type: read/write/create/delete/submit/cancel/amend) plus the
/// generic troublemakers order/group/select.
const _reserved = <String>[
  'read',
  'write',
  'create',
  'delete',
  'submit',
  'cancel',
  'amend',
  'order',
  'group',
  'select',
];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  });
  tearDown(() async => db.close());

  test(
    'sanity: an UNQUOTED reserved-word column is rejected by SQLite (pre-fix failure)',
    () async {
      // This is the exact failure mode the fix cures. If this ever stops
      // throwing, the quoting in parent_schema/child_schema is no longer
      // load-bearing and the round-trip tests below would be vacuous.
      await expectLater(
        db.execute('CREATE TABLE bad_unquoted (mobile_uuid TEXT, order TEXT)'),
        throwsA(isA<DatabaseException>()),
      );
    },
  );

  test('parent DDL with reserved-word columns CREATEs and round-trips DML',
      () async {
    final meta = DocTypeMeta(
      name: 'Reserved Parent',
      fields: _reserved.map(f).toList(),
    );
    const table = 'docs__reserved_parent';

    // CREATE must succeed (quoted identifiers).
    for (final stmt in buildParentSchemaDDL(meta, tableName: table)) {
      await db.execute(stmt);
    }

    // Every reserved word became a real column.
    final cols = (await db.rawQuery('PRAGMA table_info($table)'))
        .map((r) => r['name'] as String)
        .toSet();
    expect(cols, containsAll(_reserved));

    // INSERT values for the reserved columns (sqflite escapes identifiers on
    // the map path) alongside the NOT-NULL system columns.
    final values = <String, Object?>{
      'mobile_uuid': 'u-1',
      'local_modified': 1,
      for (final w in _reserved) w: 'val-$w',
    };
    await db.insert(table, values);

    // SELECT round-trips each reserved column's value.
    final rows = await db.query(table, where: 'mobile_uuid = ?', whereArgs: ['u-1']);
    expect(rows, hasLength(1));
    for (final w in _reserved) {
      expect(rows.first[w], 'val-$w', reason: 'column "$w" must round-trip');
    }

    // DML READ path (FilterParser) must also quote the reserved column.
    final parsed = FilterParser.toSql(
      meta: meta,
      tableName: table,
      filters: [
        ['order', '=', 'val-order'],
      ],
    );
    final filtered = await db.rawQuery(parsed.sql, parsed.params);
    expect(
      filtered,
      hasLength(1),
      reason: 'a filter on the reserved column "order" must resolve',
    );
    expect(filtered.first['mobile_uuid'], 'u-1');
  });

  test('child DDL with reserved-word columns CREATEs and round-trips DML',
      () async {
    final childMeta = DocTypeMeta(
      name: 'Reserved Child',
      isTable: true,
      fields: _reserved.map(f).toList(),
    );
    const table = 'docs__reserved_child';

    for (final stmt in buildChildSchemaDDL(childMeta, tableName: table)) {
      await db.execute(stmt);
    }

    final cols = (await db.rawQuery('PRAGMA table_info($table)'))
        .map((r) => r['name'] as String)
        .toSet();
    expect(cols, containsAll(_reserved));

    final values = <String, Object?>{
      'mobile_uuid': 'c-1',
      'parent_uuid': 'u-1',
      'parent_doctype': 'Reserved Parent',
      'parentfield': 'lines',
      'idx': 1,
      for (final w in _reserved) w: 'child-$w',
    };
    await db.insert(table, values);

    final rows = await db.query(table, where: 'mobile_uuid = ?', whereArgs: ['c-1']);
    expect(rows, hasLength(1));
    for (final w in _reserved) {
      expect(rows.first[w], 'child-$w', reason: 'child column "$w" must round-trip');
    }
  });
}
