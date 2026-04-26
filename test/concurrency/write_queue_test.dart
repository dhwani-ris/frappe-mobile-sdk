import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/write_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  });
  tearDown(() async => db.close());

  test('serializes writes', () async {
    final q = WriteQueue(db: db, doctype: 'X', batchRows: 10);
    final futs = <Future<void>>[];
    for (var i = 0; i < 5; i++) {
      futs.add(q.submit<void>((txn) async {
        await txn.insert('t', {'id': i, 'v': '$i'});
      }));
    }
    await Future.wait(futs);
    final rows = await db.query('t');
    expect(rows.length, 5);
  });

  test('propagates errors and unblocks subsequent writes', () async {
    final q = WriteQueue(db: db, doctype: 'X');
    await expectLater(
      q.submit<void>((txn) async => throw StateError('x')),
      throwsStateError,
    );
    await q.submit<void>((txn) async {
      await txn.insert('t', {'id': 99, 'v': 'a'});
    });
    final rows = await db.query('t');
    expect(rows.length, 1);
  });

  test('batches consecutive submits — 20 inserts all commit', () async {
    final q = WriteQueue(db: db, doctype: 'X', batchRows: 100);
    final futs = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      futs.add(q.submit<void>((txn) async {
        await txn.insert('t', {'id': i, 'v': '$i'});
      }));
    }
    await Future.wait(futs);
    final rows = await db.query('t');
    expect(rows.length, 20);
  });

  test('returns task result', () async {
    final q = WriteQueue(db: db, doctype: 'X');
    final r = await q.submit<int>((txn) async => 7);
    expect(r, 7);
  });
}
