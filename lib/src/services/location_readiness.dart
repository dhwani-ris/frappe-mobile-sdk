import 'package:geolocator/geolocator.dart';

import '../utils/sdk_log.dart';

/// Why the device cannot currently produce a location — or that it can.
///
/// The three failure states are kept apart because the remedy differs and only
/// one of them can be resolved by asking again: an askable denial takes the OS
/// dialog, a blocked one takes app Settings, and a disabled service takes
/// location Settings. Collapsing them would leave the user staring at a prompt
/// that cannot fix their situation.
enum LocationReadiness {
  /// Permission granted and location services on.
  ready,

  /// Permission granted (or askable) but the device's location services are
  /// switched off, so no fix can be obtained by any app.
  serviceDisabled,

  /// Not granted, and the OS will still show its dialog if asked.
  permissionDenied,

  /// Not granted, and the OS refuses to ask again — `deniedForever`. Reached on
  /// Android via "Don't ask again" (verified on device: the permission flags
  /// become `USER_FIXED` and no dialog ever appears), on Android 11+ after two
  /// denials, and on iOS after the first. Only app Settings can change it.
  permissionBlocked,
}

/// True when nothing stands between the app and a location fix.
bool isLocationReady(LocationReadiness r) => r == LocationReadiness.ready;

LocationReadiness _fromPermission(LocationPermission p) {
  switch (p) {
    case LocationPermission.always:
    case LocationPermission.whileInUse:
      return LocationReadiness.ready;
    case LocationPermission.deniedForever:
      return LocationReadiness.permissionBlocked;
    case LocationPermission.denied:
    case LocationPermission.unableToDetermine:
      // `unableToDetermine` is treated as askable rather than blocked: asking
      // is harmless and recoverable, whereas routing the user to Settings for a
      // state that a plain request would have resolved is a dead end.
      return LocationReadiness.permissionDenied;
  }
}

/// Reads the current readiness without prompting for anything.
Future<LocationReadiness> checkDeviceLocationReadiness() async {
  try {
    final permission = await Geolocator.checkPermission();
    // Permission is checked BEFORE the service, so a first-run user is asked to
    // grant before being sent to turn GPS on: the reverse order sends them to
    // Settings for a permission they were never offered.
    final fromPermission = _fromPermission(permission);
    if (fromPermission != LocationReadiness.ready) return fromPermission;
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationReadiness.serviceDisabled;
    }
    return LocationReadiness.ready;
  } catch (e, st) {
    sdkLog('checkDeviceLocationReadiness failed — $e\n$st');
    return LocationReadiness.permissionDenied;
  }
}

/// Shows the OS permission dialog and returns the resulting readiness.
///
/// A no-op that returns [LocationReadiness.permissionBlocked] when the OS has
/// stopped asking — `requestPermission` returns immediately in that state
/// rather than prompting.
Future<LocationReadiness> requestDeviceLocationPermission() async {
  try {
    final permission = await Geolocator.requestPermission();
    final result = _fromPermission(permission);
    if (result != LocationReadiness.ready) return result;
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationReadiness.serviceDisabled;
    }
    return LocationReadiness.ready;
  } catch (e, st) {
    sdkLog('requestDeviceLocationPermission failed — $e\n$st');
    return LocationReadiness.permissionDenied;
  }
}

/// Opens the app's own settings page, the only route out of
/// [LocationReadiness.permissionBlocked].
Future<void> openLocationAppSettings() async {
  try {
    await Geolocator.openAppSettings();
  } catch (e, st) {
    sdkLog('openLocationAppSettings failed — $e\n$st');
  }
}

/// Opens the device location settings page, the route out of
/// [LocationReadiness.serviceDisabled].
Future<void> openDeviceLocationSettings() async {
  try {
    await Geolocator.openLocationSettings();
  } catch (e, st) {
    sdkLog('openDeviceLocationSettings failed — $e\n$st');
  }
}
