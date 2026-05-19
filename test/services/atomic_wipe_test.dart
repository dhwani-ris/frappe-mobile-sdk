import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/atomic_wipe.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'rethrows when primary DB file delete fails — must not silently no-op',
    () async {
      // Lock the parent directory so file.delete() throws on the primary
      // suffix. Linux-only mechanism — skip on platforms where chmod can't
      // remove write permission on a directory.
      if (Platform.isWindows) return;

      final tmpRoot = Directory.systemTemp.createTempSync('sdk_test_');
      final subDir = Directory('${tmpRoot.path}/locked');
      subDir.createSync();
      final dbPath = '${subDir.path}/x.db';

      final seed = await databaseFactory.openDatabase(dbPath);
      await seed.execute('CREATE TABLE t (id INTEGER)');
      await seed.insert('t', {'id': 1});
      await seed.close();

      await Process.run('chmod', ['555', subDir.path]);

      Object? caught;
      try {
        await AtomicWipe.wipe(
          dbPath: dbPath,
          onCreate: (db) async => db.execute('CREATE TABLE t (id INTEGER)'),
        );
      } catch (e) {
        caught = e;
      }

      // Restore so the temp dir is deletable on teardown.
      await Process.run('chmod', ['755', subDir.path]);

      expect(
        caught,
        isA<FileSystemException>(),
        reason:
            'wipe must surface the primary-file delete failure as a '
            'FileSystemException, not swallow it and let onCreate fail '
            'against the surviving database.',
      );

      // The seed row must still be there — the wipe must not have
      // partially succeeded (e.g. DROPped + half-recreated tables).
      final survivor = await databaseFactory.openDatabase(dbPath);
      final rows = await survivor.query('t');
      expect(rows, hasLength(1));
      expect(rows.first['id'], 1);
      await survivor.close();
    },
  );

  test('deletes DB files (+ -wal + -shm) and recreates empty schema', () async {
    final tmp = Directory.systemTemp.createTempSync('sdk_test_').path;
    final dbPath = '$tmp/x.db';
    var db = await databaseFactory.openDatabase(dbPath);
    await db.execute('CREATE TABLE t (id INTEGER)');
    await db.insert('t', {'id': 1});
    await db.close();

    await AtomicWipe.wipe(
      dbPath: dbPath,
      onCreate: (newDb) async => newDb.execute('CREATE TABLE t (id INTEGER)'),
    );
    final again = await databaseFactory.openDatabase(dbPath);
    final rows = await again.query('t');
    expect(rows, isEmpty);
    await again.close();
  });

  test('handles missing -wal / -shm gracefully', () async {
    final tmp = Directory.systemTemp.createTempSync('sdk_test_').path;
    final dbPath = '$tmp/y.db';
    // DB never opened — file doesn't exist.
    await AtomicWipe.wipe(
      dbPath: dbPath,
      onCreate: (db) async => db.execute('CREATE TABLE t (id INTEGER)'),
    );
    final db = await databaseFactory.openDatabase(dbPath);
    final rows = await db.query('t');
    expect(rows, isEmpty);
    await db.close();
  });

  test('wipe is callable without onCreate (caller can reopen later)', () async {
    final tmp = Directory.systemTemp.createTempSync('sdk_test_').path;
    final dbPath = '$tmp/z.db';
    final db = await databaseFactory.openDatabase(dbPath);
    await db.execute('CREATE TABLE t (id INTEGER)');
    await db.insert('t', {'id': 99});
    await db.close();

    expect(File(dbPath).existsSync(), isTrue);
    await AtomicWipe.wipe(dbPath: dbPath, onCreate: (_) async {});
    // The wipe reopens the file (onCreate runs against an empty DB), so
    // the file exists but contains no application tables.
    final fresh = await databaseFactory.openDatabase(dbPath);
    final tables = await fresh.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='t'",
    );
    expect(tables, isEmpty, reason: 'old table is gone after wipe');
    await fresh.close();
  });
}
