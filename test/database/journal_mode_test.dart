import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The initial closure pull writes ~660,000 rows for a heavy Swasti
/// surveyor (measured against prod on 2026-08-19: 104,082 parents +
/// 545,367 child rows, 296 MB). The database pulled off that device
/// reported `journal_mode=delete` and `synchronous=2` — a rollback journal
/// fsynced on every commit, the slowest configuration SQLite offers for
/// bulk insert.
///
/// WAL is the fix and costs no durability: a committed transaction still
/// survives a process crash at `synchronous=FULL`, which these tests pin
/// in place. Relaxing `synchronous` was measured and not taken — the pull
/// commits once per 1000-row page, so fsync count is not where the time
/// goes, and it is not worth risking a surveyor's own save.
///
/// These tests run against a file-backed database on purpose. An in-memory
/// database forces `journal_mode=memory`, so it cannot observe any of this.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory dir;
  final opened = <AppDatabase>[];

  setUp(() async => dir = await Directory.systemTemp.createTemp('journal'));
  tearDown(() async {
    for (final db in opened) {
      await db.close();
    }
    opened.clear();
    await dir.delete(recursive: true);
  });

  var seq = 0;
  Future<AppDatabase> open() async {
    final db = await AppDatabaseTestSeam.openAt('${dir.path}/t${seq++}.db');
    opened.add(db);
    return db;
  }

  Future<String> pragma(Database db, String name) async {
    final rows = await db.rawQuery('PRAGMA $name');
    return rows.first.values.first.toString();
  }

  test('the database opens in WAL mode', () async {
    final db = await open();
    expect((await pragma(db.rawDatabase, 'journal_mode')).toLowerCase(), 'wal');
  });

  test('foreign keys stay on — WAL must not displace the existing pragma',
      () async {
    final db = await open();
    expect(await pragma(db.rawDatabase, 'foreign_keys'), '1');
  });

  test('synchronous is FULL by default, so a power cut cannot lose a save',
      () async {
    final db = await open();
    expect(await pragma(db.rawDatabase, 'synchronous'), '2');
  });

  test('a normal write still lands under WAL', () async {
    final database = await open();
    final db = database.rawDatabase;
    await db.execute('CREATE TABLE probe (k TEXT PRIMARY KEY, v TEXT)');
    await db.insert('probe', {'k': 'bulk', 'v': 'kept'});
    final rows = await db.query('probe', where: 'k = ?', whereArgs: ['bulk']);
    expect(rows.single['v'], 'kept');
  });
}
