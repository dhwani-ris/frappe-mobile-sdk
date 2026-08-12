import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;
  late Database db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('pragma_test_');
    dbPath = p.join(tempDir.path, 'test.db');
    db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(version: 1),
    );
  });

  tearDown(() async {
    await db.close();
    tempDir.deleteSync(recursive: true);
  });

  test('_onConfigure enables WAL journal mode', () async {
    await AppDatabaseTestSeam.runOnConfigure(db);
    final result = await db.rawQuery('PRAGMA journal_mode');
    expect(result.first.values.first, equals('wal'));
  });

  test('_onConfigure sets synchronous=NORMAL (1)', () async {
    await AppDatabaseTestSeam.runOnConfigure(db);
    final result = await db.rawQuery('PRAGMA synchronous');
    expect(result.first.values.first, equals(1));
  });

  test('_onConfigure sets cache_size=-32768', () async {
    await AppDatabaseTestSeam.runOnConfigure(db);
    final result = await db.rawQuery('PRAGMA cache_size');
    expect(result.first.values.first, equals(-32768));
  });

  test('_onConfigure sets mmap_size=268435456', () async {
    await AppDatabaseTestSeam.runOnConfigure(db);
    final result = await db.rawQuery('PRAGMA mmap_size');
    expect(result.first.values.first, equals(268435456));
  });

  test('_onConfigure sets temp_store=MEMORY (2)', () async {
    await AppDatabaseTestSeam.runOnConfigure(db);
    final result = await db.rawQuery('PRAGMA temp_store');
    expect(result.first.values.first, equals(2));
  });

  test('_onConfigure enables foreign_keys', () async {
    await AppDatabaseTestSeam.runOnConfigure(db);
    final result = await db.rawQuery('PRAGMA foreign_keys');
    expect(result.first.values.first, equals(1));
  });

  test(
    '_onConfigure is idempotent — second call returns same values',
    () async {
      await AppDatabaseTestSeam.runOnConfigure(db);
      await AppDatabaseTestSeam.runOnConfigure(db);
      final walResult = await db.rawQuery('PRAGMA journal_mode');
      expect(walResult.first.values.first, equals('wal'));
      final syncResult = await db.rawQuery('PRAGMA synchronous');
      expect(syncResult.first.values.first, equals(1));
    },
  );
}
