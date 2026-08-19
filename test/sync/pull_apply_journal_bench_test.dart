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

/// Compares the three journal/synchronous configurations that actually
/// ship, on the two row shapes the Swasti closure pull is made of.
///
///   before   journal_mode=delete, synchronous=FULL   (what devices had)
///   wal      journal_mode=WAL,    synchronous=FULL   (new default)
///   walBulk  journal_mode=WAL,    synchronous=NORMAL (inside the pull)
///
/// Each variant is run [kRepeats] times against a fresh on-disk database
/// and the median reported, because a single run of a few seconds is
/// dominated by whatever else the host is doing.
///
///   flutter test --dart-define=BENCH=true test/sync/pull_apply_journal_bench_test.dart
DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

const int kRows = 3000;
const int kRepeats = 3;

typedef Variant = ({String name, String journal, String sync});

const List<Variant> kVariants = [
  (name: 'before ', journal: 'DELETE', sync: 'FULL'),
  (name: 'wal    ', journal: 'WAL', sync: 'FULL'),
  (name: 'walBulk', journal: 'WAL', sync: 'NORMAL'),
];

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('journal_b'));
  tearDown(() async => dir.delete(recursive: true));

  final flatMeta = DocTypeMeta(
    name: 'Flat Doc',
    titleField: 'field00',
    searchFields: const ['field01', 'field02'],
    fields: [
      for (var i = 0; i < 40; i++)
        f('field${i.toString().padLeft(2, '0')}', i % 6 == 0 ? 'Link' : 'Data',
            options: i % 6 == 0 ? 'Some Link' : null),
    ],
  );
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
        f('field${i.toString().padLeft(2, '0')}', i % 6 == 0 ? 'Link' : 'Data',
            options: i % 6 == 0 ? 'Some Link' : null),
      f('lines', 'Table', options: 'Child Row'),
    ],
  );

  List<Map<String, dynamic>> rows(int n, int childrenPer) => [
        for (var i = 0; i < n; i++)
          <String, dynamic>{
            'name': 'ROW-${i.toString().padLeft(8, '0')}',
            'modified': '2026-08-19 10:00:00.000000',
            'docstatus': 0,
            for (var k = 0; k < 40; k++)
              'field${k.toString().padLeft(2, '0')}': 'value-$k-$i',
            if (childrenPer > 0)
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

  Future<int> runOnce({
    required Variant v,
    required String tag,
    required DocTypeMeta meta,
    required String table,
    required List<String> ddl,
    required Map<String, PullApplyChildInfo> children,
    required List<Map<String, dynamic>> page,
  }) async {
    final db = await databaseFactory.openDatabase('${dir.path}/$tag.db');
    await db.rawQuery('PRAGMA journal_mode = ${v.journal}');
    await db.execute('PRAGMA synchronous = ${v.sync}');
    for (final s in ddl) {
      await db.execute(s);
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < page.length; i += 1000) {
      await PullApply.applyPage(
        db: db,
        parentMeta: meta,
        parentTable: table,
        childMetasByFieldname: children,
        rows: page.sublist(i, (i + 1000).clamp(0, page.length)),
      );
    }
    sw.stop();
    final count =
        (await db.rawQuery('SELECT COUNT(*) AS c FROM $table')).first['c'];
    await db.close();
    expect(count, page.length, reason: tag);
    return sw.elapsedMilliseconds;
  }

  int median(List<int> xs) {
    final s = [...xs]..sort();
    return s[s.length ~/ 2];
  }

  Future<void> report({
    required String label,
    required DocTypeMeta meta,
    required String table,
    required List<String> ddl,
    required Map<String, PullApplyChildInfo> children,
    required List<Map<String, dynamic>> page,
  }) async {
    final medians = <String, int>{};
    for (final v in kVariants) {
      final runs = <int>[];
      for (var r = 0; r < kRepeats; r++) {
        runs.add(await runOnce(
          v: v,
          tag: '${label}_${v.name.trim()}_$r',
          meta: meta,
          table: table,
          ddl: ddl,
          children: children,
          page: page,
        ));
      }
      medians[v.name] = median(runs);
    }
    final base = medians[kVariants.first.name]!;
    final line = medians.entries
        .map((e) =>
            '${e.key}=${e.value}ms (${((1 - e.value / base) * 100).toStringAsFixed(0)}% faster)')
        .join('  ');
    // ignore: avoid_print
    print('JOURNAL $label rows=${page.length}  $line');
  }

  test('flat rows', () async {
    const table = 'docs__flat_doc';
    await report(
      label: 'flat ',
      meta: flatMeta,
      table: table,
      ddl: buildParentSchemaDDL(flatMeta, tableName: table),
      children: const {},
      page: rows(kRows, 0),
    );
  }, skip: kBenchSkip, timeout: const Timeout(Duration(minutes: 15)));

  test('rows with 6 children each', () async {
    const table = 'docs__parent_doc';
    const childTable = 'docs__child_row';
    await report(
      label: 'child',
      meta: parentMeta,
      table: table,
      ddl: [
        ...buildParentSchemaDDL(parentMeta, tableName: table),
        ...buildChildSchemaDDL(childMeta, tableName: childTable),
      ],
      children: {'lines': PullApplyChildInfo('Child Row', childMeta)},
      page: rows(kRows, 6),
    );
  }, skip: kBenchSkip, timeout: const Timeout(Duration(minutes: 15)));
}
