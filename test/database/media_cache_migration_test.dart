import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A v6 install is "everything systemTablesDDL builds, minus media_cache".
/// Building the full schema and dropping the new table is more honest than
/// hand-maintaining a frozen copy of the v6 DDL that would silently rot.
Future<Database> openV6Database() async {
  final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  for (final s in systemTablesDDL()) {
    await db.execute(s);
  }
  await db.execute('DROP TABLE IF EXISTS media_cache');
  await db.insert('sdk_meta', <String, Object?>{
    'id': 1,
    'schema_version': 6,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  return db;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v6 database upgrades to v7 with a media_cache table', () async {
    final db = await openV6Database();

    await AppDatabaseTestSeam.runOnUpgrade(db, 6, 7);

    final tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='media_cache'",
    );
    expect(tables, hasLength(1));

    final cols = (await db.rawQuery(
      'PRAGMA table_info(media_cache)',
    )).map((r) => r['name'] as String).toSet();
    expect(
      cols,
      containsAll(<String>[
        'file_url',
        'local_path',
        'size_bytes',
        'mime_type',
        'is_private',
        'source',
        'created_at',
        'last_accessed_at',
      ]),
    );

    await db.close();
  });

  test('migration records the new schema_version', () async {
    final db = await openV6Database();
    await AppDatabaseTestSeam.runOnUpgrade(db, 6, 7);
    final row = (await db.query('sdk_meta', where: 'id = 1')).single;
    expect(row['schema_version'], 7);
    await db.close();
  });

  test(
    'migration is idempotent (safe to re-run after a partial failure)',
    () async {
      final db = await openV6Database();
      await AppDatabaseTestSeam.runOnUpgrade(db, 6, 7);
      await AppDatabaseTestSeam.runOnUpgrade(db, 6, 7);
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='media_cache'",
      );
      expect(tables, hasLength(1));
      await db.close();
    },
  );

  test('file_url is the primary key so one url caches exactly once', () async {
    final db = await openV6Database();
    await AppDatabaseTestSeam.runOnUpgrade(db, 6, 7);

    final pk = (await db.rawQuery('PRAGMA table_info(media_cache)'))
        .where((r) => (r['pk'] as int? ?? 0) > 0)
        .map((r) => r['name'] as String)
        .toList();
    expect(pk, ['file_url']);

    await db.close();
  });

  test('AppDatabase version is 7', () {
    expect(AppDatabaseTestSeam.version, 7);
  });
}
