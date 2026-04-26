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

  set value(SyncState next) {
    _value = next;
    _controller.add(next);
  }

  Stream<SyncState> get stream => _controller.stream;

  Future<void> close() => _controller.close();
}
