import 'dart:async';

/// Single-occupant mutex. Used by [SyncService] to guarantee at most
/// one concurrent sync (push or pull). Two acquisition modes:
///
/// - [tryProtect]: bail immediately with `null` when the mutex is held
///   so the public API can return "Sync already in progress" without
///   making the user wait. Use for user-initiated syncs.
/// - [protect]: queue behind the current holder and run when the mutex
///   becomes free. Use for background-driven refreshes (e.g. Link
///   picker prefetch) where dropping the request leaves the UI stale,
///   but waiting for the in-flight batch to drain is acceptable.
///
/// The lock is held for the duration of the `body` future. If `body`
/// throws, the lock is released and the exception propagates.
class SyncMutex {
  Completer<void>? _busy;

  /// Returns `null` when the mutex is already held; otherwise runs [body]
  /// to completion and releases the mutex.
  Future<T?> tryProtect<T>(Future<T> Function() body) async {
    if (_busy != null) return null;
    final c = Completer<void>();
    _busy = c;
    try {
      return await body();
    } finally {
      _busy = null;
      c.complete();
    }
  }

  /// Waits for the current holder (if any) to release, then runs [body]
  /// to completion. Multiple waiters serialize FIFO via successive
  /// `await`s on the in-flight completer.
  Future<T> protect<T>(Future<T> Function() body) async {
    while (_busy != null) {
      await _busy!.future;
    }
    final c = Completer<void>();
    _busy = c;
    try {
      return await body();
    } finally {
      _busy = null;
      c.complete();
    }
  }
}
