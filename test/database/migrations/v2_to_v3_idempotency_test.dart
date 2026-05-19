import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'doctypeMetaExtensionsDDL applied twice (with duplicate-column guard) does not throw',
    () async {
      // Simulates the _onUpgrade re-entry scenario: a partial v2→v3
      // migration crashes after some ALTERs succeed, then the app restarts
      // and runs _onUpgrade again. The second run must NOT throw "duplicate
      // column name" — production code wraps each ALTER in a try/catch on
      // that error, and this test pins the contract.
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      addTearDown(() => db.close());

      // Build a "post-v2" doctype_meta with the original columns only.
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

      Future<void> applyWithGuard() async {
        for (final stmt in doctypeMetaExtensionsDDL()) {
          try {
            await db.execute(stmt);
          } on DatabaseException catch (e) {
            if (!e.toString().toLowerCase().contains('duplicate column')) {
              rethrow;
            }
          }
        }
      }

      // First run — applies all 9 ALTERs.
      await applyWithGuard();
      final colsAfterFirst = (await db.rawQuery(
        'PRAGMA table_info(doctype_meta)',
      )).map((r) => r['name'] as String).toSet();
      expect(
        colsAfterFirst,
        containsAll(<String>{
          'table_name',
          'meta_watermark',
          'dep_graph_json',
          'last_ok_cursor',
          'last_pull_started_at',
          'last_pull_ok_at',
          'is_entry_point',
          'is_child_table',
          'record_count',
        }),
      );

      // Second run — every ALTER throws "duplicate column", but the guard
      // swallows them. The call must complete normally.
      await expectLater(applyWithGuard(), completes);

      // Third run — same expectation, just to be sure idempotency holds
      // across N retries.
      await expectLater(applyWithGuard(), completes);

      // Schema is unchanged (no extra columns, no missing ones).
      final colsAfterThird = (await db.rawQuery(
        'PRAGMA table_info(doctype_meta)',
      )).map((r) => r['name'] as String).toSet();
      expect(colsAfterThird, equals(colsAfterFirst));
    },
  );
}
