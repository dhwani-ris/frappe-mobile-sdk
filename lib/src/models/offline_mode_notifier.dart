import 'offline_mode.dart';

/// Mutable holder for the session-bound [OfflineMode].
///
/// Threaded through `SyncService`, `OfflineRepository`, and
/// `UnifiedResolver` from `FrappeSDK` so a mid-session flip
/// (after login) is visible to every service without rebuilding them.
class OfflineModeNotifier {
  OfflineMode value;
  OfflineModeNotifier(this.value);
}
