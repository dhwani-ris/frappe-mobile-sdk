import 'dart:io';

/// Maps device specs (RAM, cores) to a concurrency level for the SDK's
/// HTTP and isolate pools. Spec §8 thresholds:
///
/// | Spec                            | Concurrency |
/// |---------------------------------|-------------|
/// | RAM ≤ 3 GB OR cores ≤ 4         | 2           |
/// | RAM ≤ 6 GB OR cores ≤ 6         | 4           |
/// | otherwise                       | 8           |
class DeviceTier {
  /// Pure function — testable without `device_info_plus`.
  static int concurrencyForSpecs({
    required int totalRamMb,
    required int cores,
    int? override,
  }) {
    if (override != null) return override;
    if (totalRamMb <= 3000 || cores <= 4) return 2;
    if (totalRamMb <= 6000 || cores <= 6) return 4;
    return 8;
  }

  /// Runtime detector. Reads only what's cheaply available across platforms
  /// (`Platform.numberOfProcessors`); RAM signals are platform-specific and
  /// vary in reliability, so we treat unknown RAM as "very large" and let
  /// the cores threshold decide.
  ///
  /// Falls back to `2` if anything throws — safest assumption on low-end
  /// Android where unexpected exceptions during boot would otherwise crash
  /// initialisation.
  static Future<int> detect({int? override}) async {
    if (override != null) return override;
    try {
      final cores = Platform.numberOfProcessors;
      return concurrencyForSpecs(totalRamMb: 1000000, cores: cores);
    } catch (_) {
      return 2;
    }
  }
}
