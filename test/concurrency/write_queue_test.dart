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
      futs.add(
        q.submit<void>((txn) async {
          await txn.insert('t', {'id': i, 'v': '$i'});
        }),
      );
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
      futs.add(
        q.submit<void>((txn) async {
          await txn.insert('t', {'id': i, 'v': '$i'});
        }),
      );
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

  test(
    'failed task in batch does not commit its partial writes; siblings do',
    () async {
      // SIG-1: per-task isolation via SQLite savepoints. The outer
      // transaction batches up to `batchRows` tasks for one fsync, but a
      // failure in task[1] must roll back only task[1]'s writes — task[0]
      // and task[2] still commit. Without savepoints, the swallowed
      // exception left task[1]'s partial writes inside the same outer
      // transaction, which then committed alongside the siblings.
      final q = WriteQueue(db: db, doctype: 'X', batchRows: 10);

      final f0 = q.submit<void>((txn) async {
        await txn.insert('t', {'id': 1, 'v': 'one'});
      });
      final f1 = q.submit<void>((txn) async {
        await txn.insert('t', {'id': 2, 'v': 'TWO-PARTIAL'});
        // Throw AFTER the insert so we can prove the insert was rolled back.
        throw StateError('boom');
      });
      final f2 = q.submit<void>((txn) async {
        await txn.insert('t', {'id': 3, 'v': 'three'});
      });

      await expectLater(f0, completes);
      await expectLater(f1, throwsStateError);
      await expectLater(f2, completes);

      final rows = await db.query('t', orderBy: 'id ASC');
      expect(
        rows.map((r) => r['id']).toList(),
        [1, 3],
        reason: 'task[1] partial insert must have been rolled back',
      );
    },
  );
}
