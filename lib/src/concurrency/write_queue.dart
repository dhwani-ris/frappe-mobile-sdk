import 'dart:async';
import 'dart:collection';

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
/// keeping fsync amortised across writes. A failure in one task only
/// fails that task; the remaining batch tasks continue inside the same
/// transaction.
class WriteQueue {
  final Database db;
  final String doctype;
  final int batchRows;

  final Queue<_PendingWrite<Object?>> _queue = Queue();
  bool _running = false;

  WriteQueue({
    required this.db,
    required this.doctype,
    this.batchRows = 50,
  });

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
          await db.transaction((txn) async {
            var count = 0;
            while (_queue.isNotEmpty && count < batchRows) {
              final p = _queue.removeFirst();
              try {
                final r = await p.task(txn);
                p.completer.complete(r);
              } catch (e, st) {
                p.completer.completeError(e, st);
              }
              count++;
            }
          });
        }
      } finally {
        _running = false;
      }
    });
  }
}
