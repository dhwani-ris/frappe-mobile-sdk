import 'dart:async';
import 'sync_state.dart';

/// Holds the latest [SyncState] snapshot and broadcasts every assignment to
/// subscribers. Modelled after `ValueNotifier` but uses a broadcast stream
/// so multiple widgets can listen independently and the SDK can hand out
/// the stream as a public read-only surface.
class SyncStateNotifier {
  SyncState _value = SyncState.initial;
  final StreamController<SyncState> _controller =
      StreamController<SyncState>.broadcast();

  SyncState get value => _value;

  /// Setter short-circuits when [next] is value-equal to the current value
  /// (relies on [SyncState.==]). This means listeners — including widget
  /// trees subscribed via `StreamBuilder` — do not rebuild when a tick of
  /// engine bookkeeping produces an identical snapshot.
  set value(SyncState next) {
    if (_value == next) return;
    _value = next;
    _controller.add(next);
  }

  Stream<SyncState> get stream => _controller.stream;

  /// Records a per-doctype meta-sync failure on
  /// [SyncState.failedMetaSyncs]. Caller (typically [MetaService]) should
  /// pass the doctype name and a short error description. Idempotent —
  /// re-recording the same `(doctype, error)` is a no-op (short-circuits
  /// via [SyncState.==]).
  void recordMetaSyncFailure(String doctype, String error) {
    final current = _value.failedMetaSyncs;
    if (current[doctype] == error) return;
    final next = Map<String, String>.from(current);
    next[doctype] = error;
    value = _value.copyWith(failedMetaSyncs: next);
  }

  /// Clears a doctype's entry from [SyncState.failedMetaSyncs] — called
  /// after a subsequent successful meta sync to lower the counter. No-op
  /// if no entry exists.
  void clearMetaSyncFailure(String doctype) {
    final current = _value.failedMetaSyncs;
    if (!current.containsKey(doctype)) return;
    final next = Map<String, String>.from(current)..remove(doctype);
    value = _value.copyWith(failedMetaSyncs: next);
  }

  Future<void> close() => _controller.close();
}
