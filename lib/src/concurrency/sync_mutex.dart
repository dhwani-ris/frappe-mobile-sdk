import 'dart:async';

/// Single-occupant mutex with try-only semantics. Used by [SyncService] to
/// guarantee at most one concurrent sync (push or pull) — the second caller
/// bails immediately with `null` so the public API can return
/// "Sync already in progress" without making the user wait.
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
}
