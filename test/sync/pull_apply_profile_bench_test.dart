@Tags(['bench'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/child_schema.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Benchmarks print timings; they are measurement tools, not gates, and add
/// ~45s to a run. Skipped unless asked for explicitly:
///
///   flutter test --dart-define=BENCH=true <this file>
const bool kRunBench = bool.fromEnvironment('BENCH');
const Object? kBenchSkip =
    kRunBench ? null : 'measurement only — pass --dart-define=BENCH=true';

/// Breaks the initial-pull apply cost into its parts so an optimisation can
/// be argued from numbers rather than intuition.
///
/// Variants measured, all applying the SAME 2000 rows into an EMPTY on-disk
/// database (the initial-sync case — every row is an INSERT):
///
///   baseline    current shape: 7 indexes present, default journal/sync
///   walNormal   + `PRAGMA journal_mode=WAL` + `PRAGMA synchronous=NORMAL`
///   noIndexes   indexes created AFTER the load instead of before
///   both        walNormal + noIndexes
///
/// And, for the child-bearing shape (Document Application: ~6 child rows per
/// parent), the same four.
///
///   flutter test --dart-define=BENCH=true test/sync/pull_apply_profile_bench_test.dart
DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

const int kRows = 2000;

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('pull_prof'));
  tearDown(() async => dir.delete(recursive: true));

  // ---- flat parent, Scheme Application Followup shape -------------------
  final flatMeta = DocTypeMeta(
    name: 'Flat Doc',
    titleField: 'field00',
    searchFields: const ['field01', 'field02'],
    fields: [
      for (var i = 0; i < 40; i++)
        f(
          'field${i.toString().padLeft(2, '0')}',
          i % 6 == 0 ? 'Link' : 'Data',
          options: i % 6 == 0 ? 'Some Link' : null,
        ),
    ],
  );

  // ---- parent + child, Document Application shape -----------------------
  final childMeta = DocTypeMeta(
    name: 'Child Row',
    isTable: true,
    fields: [f('code', 'Data'), f('qty', 'Int'), f('note', 'Data')],
  );
  final parentMeta = DocTypeMeta(
    name: 'Parent Doc',
    titleField: 'field00',
    searchFields: const ['field01'],
    fields: [
      for (var i = 0; i < 40; i++)
        f(
          'field${i.toString().padLeft(2, '0')}',
          i % 6 == 0 ? 'Link' : 'Data',
          options: i % 6 == 0 ? 'Some Link' : null,
        ),
      f('lines', 'Table', options: 'Child Row'),
    ],
  );

  List<Map<String, dynamic>> flatRows(int n) => [
        for (var i = 0; i < n; i++)
          <String, dynamic>{
            'name': 'ROW-${i.toString().padLeft(8, '0')}',
            'modified': '2026-08-19 10:00:00.000000',
            'docstatus': 0,
            for (var k = 0; k < 40; k++)
              'field${k.toString().padLeft(2, '0')}': 'value-$k-$i',
          },
      ];

  List<Map<String, dynamic>> childBearingRows(int n, int childrenPer) => [
        for (var i = 0; i < n; i++)
          <String, dynamic>{
            'name': 'ROW-${i.toString().padLeft(8, '0')}',
            'modified': '2026-08-19 10:00:00.000000',
            'docstatus': 0,
            for (var k = 0; k < 40; k++)
              'field${k.toString().padLeft(2, '0')}': 'value-$k-$i',
            'lines': [
              for (var c = 0; c < childrenPer; c++)
                <String, dynamic>{
                  'name': 'ROW-${i.toString().padLeft(8, '0')}-$c',
                  'parentfield': 'lines',
                  'idx': c + 1,
                  'code': 'CODE-$c',
                  'qty': c,
                  'note': 'note-$i-$c',
                },
            ],
          },
      ];

  /// Opens a fresh file DB, optionally with WAL+NORMAL, and creates the
  /// schema either fully (indexes up front) or table-only.
  Future<Database> openWith({
    required String name,
    required bool walNormal,
    required bool indexesUpFront,
    required List<String> parentDdl,
    List<String> childDdl = const [],
  }) async {
    final db = await databaseFactory.openDatabase('${dir.path}/$name.db');
    if (walNormal) {
      await db.rawQuery('PRAGMA journal_mode = WAL');
      await db.execute('PRAGMA synchronous = NORMAL');
    }
    for (final s in [...parentDdl, ...childDdl]) {
      final isIndex = s.startsWith('CREATE UNIQUE INDEX') ||
          s.startsWith('CREATE INDEX');
      // The UNIQUE server_name index is load-bearing for the apply's
      // existence lookup, so it is never deferred.
      final isServerName = s.contains('_server_name ');
      if (isIndex && !indexesUpFront && !isServerName) continue;
      await db.execute(s);
    }
    return db;
  }

  Future<int> timeApply({
    required Database db,
    required DocTypeMeta meta,
    required String table,
    required Map<String, PullApplyChildInfo> children,
    required List<Map<String, dynamic>> rows,
    required List<String> deferredIndexDdl,
  }) async {
    final sw = Stopwatch()..start();
    // The engine applies a page at a time; page size is 1000.
    for (var i = 0; i < rows.length; i += 1000) {
      final page = rows.sublist(i, (i + 1000).clamp(0, rows.length));
      await PullApply.applyPage(
        db: db,
        parentMeta: meta,
        parentTable: table,
        childMetasByFieldname: children,
        rows: page,
      );
    }
    for (final s in deferredIndexDdl) {
      await db.execute(s);
    }
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  test('flat parent — index and pragma variants', () async {
    const table = 'docs__flat_doc';
    final ddl = buildParentSchemaDDL(flatMeta, tableName: table);
    final deferred = ddl
        .where((s) =>
            (s.startsWith('CREATE INDEX') ||
                s.startsWith('CREATE UNIQUE INDEX')) &&
            !s.contains('_server_name '))
        .toList();
    final rows = flatRows(kRows);
    final results = <String, int>{};

    for (final variant in const [
      ('baseline', false, true),
      ('walNormal', true, true),
      ('noIndexes', false, false),
      ('both', true, false),
    ]) {
      final db = await openWith(
        name: 'flat_${variant.$1}',
        walNormal: variant.$2,
        indexesUpFront: variant.$3,
        parentDdl: ddl,
      );
      results[variant.$1] = await timeApply(
        db: db,
        meta: flatMeta,
        table: table,
        children: const {},
        rows: rows,
        deferredIndexDdl: variant.$3 ? const [] : deferred,
      );
      final c = (await db.rawQuery('SELECT COUNT(*) AS c FROM $table'))
          .first['c'];
      expect(c, kRows, reason: variant.$1);
      await db.close();
    }
    // ignore: avoid_print
    print('PROFILE flat rows=$kRows indexes=${1 + deferred.length}  '
        '${results.entries.map((e) => '${e.key}=${e.value}ms').join('  ')}');
  }, skip: kBenchSkip, timeout: const Timeout(Duration(minutes: 10)));

  test('parent with 6 child rows each — index and pragma variants', () async {
    const table = 'docs__parent_doc';
    const childTable = 'docs__child_row';
    final ddl = buildParentSchemaDDL(parentMeta, tableName: table);
    final cddl = buildChildSchemaDDL(childMeta, tableName: childTable);
    final deferred = [...ddl, ...cddl]
        .where((s) =>
            (s.startsWith('CREATE INDEX') ||
                s.startsWith('CREATE UNIQUE INDEX')) &&
            !s.contains('_server_name '))
        .toList();
    final rows = childBearingRows(kRows, 6);
    final children = {'lines': PullApplyChildInfo('Child Row', childMeta)};
    final results = <String, int>{};

    for (final variant in const [
      ('baseline', false, true),
      ('walNormal', true, true),
      ('noIndexes', false, false),
      ('both', true, false),
    ]) {
      final db = await openWith(
        name: 'child_${variant.$1}',
        walNormal: variant.$2,
        indexesUpFront: variant.$3,
        parentDdl: ddl,
        childDdl: cddl,
      );
      results[variant.$1] = await timeApply(
        db: db,
        meta: parentMeta,
        table: table,
        children: children,
        rows: rows,
        deferredIndexDdl: variant.$3 ? const [] : deferred,
      );
      final c = (await db.rawQuery('SELECT COUNT(*) AS c FROM $childTable'))
          .first['c'];
      expect(c, kRows * 6, reason: variant.$1);
      await db.close();
    }
    // ignore: avoid_print
    print('PROFILE child rows=$kRows (+${kRows * 6} child)  '
        '${results.entries.map((e) => '${e.key}=${e.value}ms').join('  ')}');
  }, skip: kBenchSkip, timeout: const Timeout(Duration(minutes: 10)));
}
