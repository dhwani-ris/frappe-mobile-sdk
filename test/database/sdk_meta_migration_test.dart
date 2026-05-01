import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v4 sdk_meta → v5 adds offline_enabled and set_at columns', () async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 4,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE sdk_meta (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            schema_version INTEGER NOT NULL DEFAULT 0,
            session_user_json TEXT,
            bootstrap_done INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute(
          'INSERT INTO sdk_meta (id, schema_version) VALUES (1, 0)',
        );
      },
      singleInstance: false,
    );

    for (final stmt in sdkMetaV5ExtensionsDDL()) {
      await db.execute(stmt);
    }

    final columns = await db.rawQuery('PRAGMA table_info(sdk_meta)');
    final names = columns.map((c) => c['name'] as String).toList();
    expect(names, containsAll(['offline_enabled', 'offline_enabled_set_at']));

    final rows = await db.rawQuery(
      'SELECT offline_enabled, offline_enabled_set_at FROM sdk_meta WHERE id=1',
    );
    expect(rows.first['offline_enabled'], 0);
    expect(rows.first['offline_enabled_set_at'], isNull);

    await db.close();
  });

  test('v5 ALTER on a fresh-install schema raises duplicate-column', () async {
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 5,
      onCreate: (db, _) async {
        for (final stmt in systemTablesDDL()) {
          await db.execute(stmt);
        }
      },
      singleInstance: false,
    );

    bool threw = false;
    try {
      await db.execute(sdkMetaV5ExtensionsDDL().first);
    } on DatabaseException catch (e) {
      if (e.toString().toLowerCase().contains('duplicate column')) {
        threw = true;
      }
    }
    expect(
      threw,
      isTrue,
      reason:
          'AppDatabase._onUpgrade tolerates this; the test asserts the precondition holds',
    );

    await db.close();
  });
}
