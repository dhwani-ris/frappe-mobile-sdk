import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

typedef WriteTask<T> = Future<T> Function(Transaction txn);

/// Returns the [WriteQueue] for a given doctype. Engines that wire this
/// resolver build one queue per parent doctype on first use and route
/// every write through it so SQLite write contention is per-doctype-serial
/// across all pull/push activity, and consecutive writes amortise fsync
/// via the queue's batched-transaction behavior.
typedef WriteQueueResolver = WriteQueue Function(String doctype);

class _PendingWrite<T> {
  final WriteTask<T> task;
  final Completer<T> completer = Completer<T>();
  _PendingWrite(this.task);
}

/// Per-doctype serial write queue. Submits run inside a single sqflite
/// `db.transaction(...)` block, with consecutive submits batched into the
/// same transaction up to [batchRows]. Different doctypes use independent
/// queues so they never block each other.
///
/// One transaction per batch — eliminates SQLite write contention while
/// keeping fsync amortised across writes. Per-task isolation is provided
/// by SQLite savepoints: a failed task is rolled back to its savepoint
/// (its partial writes are discarded) without aborting the outer
/// transaction or affecting sibling tasks.
class WriteQueue {
  final Database db;
  final String doctype;
  final int batchRows;

  final Queue<_PendingWrite<Object?>> _queue = Queue();
  bool _running = false;
  int _savepointCounter = 0;

  WriteQueue({required this.db, required this.doctype, this.batchRows = 50});

  Future<T> submit<T>(WriteTask<T> task) {
    final p = _PendingWrite<Object?>(
      (txn) async => (await task(txn)) as Object?,
    );
    _queue.add(p);
    _kick();
    return p.completer.future.then((v) => v as T);
  }

  void _kick() {
    if (_running) return;
    _running = true;
    Future<void>(() async {
      try {
        while (_queue.isNotEmpty) {
          try {
            await db.transaction((txn) async {
              var count = 0;
              while (_queue.isNotEmpty && count < batchRows) {
                final p = _queue.removeFirst();
                final sp = 'wq_${++_savepointCounter}';
                try {
                  await txn.execute('SAVEPOINT $sp');
                  final r = await p.task(txn);
                  await txn.execute('RELEASE SAVEPOINT $sp');
                  p.completer.complete(r);
                } catch (e, st) {
                  // Roll back this task's partial writes; sibling tasks
                  // inside the same outer transaction are unaffected.
                  try {
                    await txn.execute('ROLLBACK TO SAVEPOINT $sp');
                    await txn.execute('RELEASE SAVEPOINT $sp');
                  } catch (rollbackErr, rollbackSt) {
                    // Savepoint may not exist if the SAVEPOINT itself failed.
                    debugPrint(
                      'WriteQueue: ROLLBACK TO SAVEPOINT $sp failed — $rollbackErr\n$rollbackSt',
                    );
                  }
                  p.completer.completeError(e, st);
                }
                count++;
              }
            });
          } catch (e, st) {
            // Outer `db.transaction` itself failed (e.g. database closed,
            // disk full, lock timeout). Items already removed inside the
            // inner loop were completed via the per-task savepoint
            // try/catch. Items still queued would otherwise hang forever
            // on `submit()` — drain them with the same error so callers
            // observe the failure and can recover or surface it.
            debugPrint('WriteQueue: outer transaction failed — $e\n$st');
            while (_queue.isNotEmpty) {
              _queue.removeFirst().completer.completeError(e, st);
            }
          }
        }
      } finally {
        _running = false;
      }
    });
  }
}
