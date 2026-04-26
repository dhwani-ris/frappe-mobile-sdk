import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

typedef OnRestoreCallback = void Function();

/// Tracks online/offline state. Two construction paths:
///
/// - [ConnectivityWatcher.fromStream] — used by tests with a synthetic
///   `Stream<bool>`, no platform plugin.
/// - [ConnectivityWatcher.production] — wires up the real
///   `connectivity_plus` event stream.
///
/// Callers can subscribe to [onChange] for every transition or register
/// one-shot-per-transition `addOnRestoreCallback` handlers that fire only
/// on the offline → online edge (used by the pull engine to drain
/// deferred doctypes).
class ConnectivityWatcher {
  bool _isOnline;
  final StreamController<bool> _controller =
      StreamController<bool>.broadcast();
  final List<OnRestoreCallback> _onRestoreCallbacks = [];

  ConnectivityWatcher._(this._isOnline);

  factory ConnectivityWatcher.fromStream({
    required bool initial,
    required Stream<bool> stream,
  }) {
    final w = ConnectivityWatcher._(initial);
    stream.listen(w._onEvent);
    return w;
  }

  static Future<ConnectivityWatcher> production() async {
    final connectivity = Connectivity();
    final initial = !(await connectivity.checkConnectivity())
        .contains(ConnectivityResult.none);
    final stream = connectivity.onConnectivityChanged.map(
      (results) => !results.contains(ConnectivityResult.none),
    );
    return ConnectivityWatcher.fromStream(initial: initial, stream: stream);
  }

  bool get isOnline => _isOnline;
  Stream<bool> get onChange => _controller.stream;

  void addOnRestoreCallback(OnRestoreCallback cb) =>
      _onRestoreCallbacks.add(cb);

  void _onEvent(bool nextOnline) {
    final wasOffline = !_isOnline;
    _isOnline = nextOnline;
    _controller.add(nextOnline);
    if (wasOffline && nextOnline) {
      for (final cb in _onRestoreCallbacks) {
        cb();
      }
    }
  }
}
