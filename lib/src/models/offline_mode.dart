/// Server-driven offline mode flag bound to a session.
///
/// Constructed once per `FrappeSDK.initialize()` call; never mutated.
/// `isPersisted = false` means the SDK has never received a login
/// response carrying `offline_enabled` — distinguishes a fresh install
/// (or a just-upgraded SDK) from one that has been told a real value.
class OfflineMode {
  final bool enabled;
  final bool isPersisted;

  const OfflineMode({required this.enabled, required this.isPersisted});

  static const fallback = OfflineMode(enabled: false, isPersisted: false);

  @override
  bool operator ==(Object other) =>
      other is OfflineMode &&
      other.enabled == enabled &&
      other.isPersisted == isPersisted;

  @override
  int get hashCode => Object.hash(enabled, isPersisted);

  @override
  String toString() =>
      'OfflineMode(enabled: $enabled, isPersisted: $isPersisted)';
}
