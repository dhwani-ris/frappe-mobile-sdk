/// Decides whether the running build is too old to continue.
///
/// [expected] is `Mobile Configuration.minimum_app_version`. Two shapes are
/// supported, deliberately:
///
///   * **Integer** — a build number (Android `versionCode`). Compared as a
///     true MINIMUM: blocked only when the running build is strictly below
///     it. Swasti needs this shape because the version NAME is `1.0.2` for
///     every build from +48 to +54 and cannot distinguish them.
///   * **Anything else** — treated as an exact pin and compared with `!=`,
///     which is the behaviour existing consumers of this SDK rely on.
///
/// A null, empty or whitespace-only [expected] never blocks: a site that has
/// not configured a floor must not be able to lock its own fleet out by
/// accident.
///
/// An integer floor against an unparseable [current] is treated as a
/// mismatch. `PackageInfo.buildNumber` is always populated on Android, so
/// this case means the app cannot report its own build — which is not a
/// state to grant the benefit of the doubt.
bool appUpdateRequired({String? expected, String? current}) {
  final floor = (expected ?? '').trim();
  if (floor.isEmpty) return false;

  final running = (current ?? '').trim();

  final floorBuild = int.tryParse(floor);
  final runningBuild = int.tryParse(running);
  if (floorBuild != null && runningBuild != null) {
    return runningBuild < floorBuild;
  }

  return floor != running;
}
