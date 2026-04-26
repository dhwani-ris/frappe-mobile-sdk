import 'dart:async';
import 'dart:collection';

class _Pending<T> {
  final Future<T> Function() task;
  final Completer<T> completer = Completer<T>();
  _Pending(this.task);
}

/// FIFO bounded-parallel executor. At most [maxConcurrent] tasks run at a
/// time; the rest queue and dispatch in submission order.
///
/// One instance per pool kind in the SDK: [PullPool] for pull GETs,
/// [PushPool] for outbox dispatch (P4). Sizes are taken from
/// [DeviceTier.concurrencyForSpecs] (2 / 4 / 8) and can be raised at
/// runtime via [resize] — already-running tasks complete under the old
/// cap; only new dispatches honor the new cap.
class ConcurrencyPool {
  int _maxConcurrent;
  int _inFlight = 0;
  final Queue<_Pending<Object?>> _queue = Queue();

  ConcurrencyPool({required int maxConcurrent})
      : _maxConcurrent = maxConcurrent;

  int get maxConcurrent => _maxConcurrent;

  void resize(int newMax) {
    _maxConcurrent = newMax;
    _drain();
  }

  Future<T> submit<T>(Future<T> Function() task) {
    final p = _Pending<Object?>(() async => (await task()) as Object?);
    _queue.add(p);
    _drain();
    return p.completer.future.then((v) => v as T);
  }

  void _drain() {
    while (_inFlight < _maxConcurrent && _queue.isNotEmpty) {
      final p = _queue.removeFirst();
      _inFlight++;
      Future<void>(() async {
        try {
          final r = await p.task();
          p.completer.complete(r);
        } catch (e, st) {
          p.completer.completeError(e, st);
        } finally {
          _inFlight--;
          _drain();
        }
      });
    }
  }
}
