@Tags(['bench'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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

/// Measures the cost of the pull loop's per-row `applyPage(rows: [doc])`
/// against a single `applyPage(rows: page)` for the same 1000 rows.
///
/// Runs against an on-disk file, not `inMemoryDatabasePath` — the whole point
/// is transaction commit cost, which an in-memory database does not pay.
///
/// Run with
///   flutter test --dart-define=BENCH=true test/sync/pull_apply_page_batching_bench_test.dart
DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // A parent shaped like Scheme Application Followup: ~40 flat columns,
  // no child tables.
  final meta = DocTypeMeta(
    name: 'Bench Doc',
    titleField: 'field00',
    fields: [
      for (var i = 0; i < 40; i++) f('field${i.toString().padLeft(2, '0')}',
          i % 5 == 0 ? 'Link' : 'Data',
          options: i % 5 == 0 ? 'Bench Link' : null),
    ],
  );
  const table = 'docs__bench_doc';

  List<Map<String, dynamic>> page(int n, int offset) => [
        for (var i = 0; i < n; i++)
          <String, dynamic>{
            'name': 'BENCH-${(offset + i).toString().padLeft(8, '0')}',
            'modified': '2026-08-19 10:00:00.000000',
            'docstatus': 0,
            for (var k = 0; k < 40; k++)
              'field${k.toString().padLeft(2, '0')}': 'value-$k-$i',
          },
      ];

  Future<Database> freshDb(Directory dir, String name) async {
    final db = await databaseFactory.openDatabase('${dir.path}/$name.db');
    for (final s in buildParentSchemaDDL(meta, tableName: table)) {
      await db.execute(s);
    }
    return db;
  }

  test('per-row transactions vs one transaction per page — 1000 rows', () async {
    final dir = await Directory.systemTemp.createTemp('pull_apply_bench');
    addTearDown(() => dir.delete(recursive: true));

    const rows = 1000;

    final perRowDb = await freshDb(dir, 'per_row');
    final swRow = Stopwatch()..start();
    for (final doc in page(rows, 0)) {
      await PullApply.applyPage(
        db: perRowDb,
        parentMeta: meta,
        parentTable: table,
        childMetasByFieldname: const {},
        rows: [doc],
      );
    }
    swRow.stop();
    await perRowDb.close();

    final perPageDb = await freshDb(dir, 'per_page');
    final swPage = Stopwatch()..start();
    await PullApply.applyPage(
      db: perPageDb,
      parentMeta: meta,
      parentTable: table,
      childMetasByFieldname: const {},
      rows: page(rows, 0),
    );
    swPage.stop();
    final count =
        (await perPageDb.rawQuery('SELECT COUNT(*) AS c FROM $table'))
            .first['c'];
    await perPageDb.close();

    expect(count, rows);

    // ignore: avoid_print
    print(
      'BENCH rows=$rows  per-row=${swRow.elapsedMilliseconds}ms  '
      'per-page=${swPage.elapsedMilliseconds}ms  '
      'speedup=${(swRow.elapsedMicroseconds / swPage.elapsedMicroseconds).toStringAsFixed(1)}x',
    );
  }, skip: kBenchSkip, timeout: const Timeout(Duration(minutes: 5)));
}
