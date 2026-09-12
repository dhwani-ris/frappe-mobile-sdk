import 'package:geolocator/geolocator.dart';

import '../utils/geo_json.dart';
import '../utils/sdk_log.dart';
import 'location_readiness.dart';

/// How long [PendingCreationMeta.location] waits at save time for a fix that
/// has not landed yet. Deliberately far below the 15s GPS read budget: a save
/// that stalls on a cold fix is worse for field work than an empty location.
const Duration kCreationLocationSaveWait = Duration(seconds: 3);

/// Captures the metadata Frappe's mobile Custom Fields record about *when and
/// where a record was started*, as distinct from when it was saved.
///
/// The distinction is the whole point of the two fields. Stamping them at save
/// time would make `mobile_created_at` a duplicate of Frappe's own `creation`
/// and would place `mobile_latitude_longitude` wherever the user happened to
/// be when they pressed Save. So capture begins the moment a new-record form
/// opens (or a child row's Add Row is tapped) and the values are held here
/// until that record is written.
///
/// The timestamp is available synchronously and is therefore always reliable.
/// The location is inherently not: it needs a permission grant and a satellite
/// fix, so it is read in the background and collected on a best-effort basis.
///
/// [now] and [readLocation] are injectable so the capture logic is testable
/// without a device; both default to the real implementations.
class MobileCreationCapture {
  MobileCreationCapture({
    DateTime Function()? now,
    Future<String?> Function()? readLocation,
    Future<LocationReadiness> Function()? checkReadiness,
    Future<LocationReadiness> Function()? requestPermission,
    this.saveWait = kCreationLocationSaveWait,
  }) : _now = now ?? DateTime.now,
       _readLocation = readLocation ?? readDeviceLocationAsGeoJson,
       _checkReadiness = checkReadiness ?? checkDeviceLocationReadiness,
       _requestPermission =
           requestPermission ?? requestDeviceLocationPermission;

  final DateTime Function() _now;
  final Future<String?> Function() _readLocation;
  final Future<LocationReadiness> Function() _checkReadiness;
  final Future<LocationReadiness> Function() _requestPermission;

  /// Current readiness, without prompting. The form gates on this before it
  /// lets a new record be filled in, so a record can never be started while
  /// the device is incapable of locating it.
  Future<LocationReadiness> readiness() => _checkReadiness();

  /// Shows the OS permission dialog and returns the resulting readiness.
  /// Returns [LocationReadiness.permissionBlocked] unchanged when the OS has
  /// stopped asking — in that state only app Settings can help.
  Future<LocationReadiness> requestPermission() => _requestPermission();

  /// How long [PendingCreationMeta.location] waits by default. Overridable so a
  /// test can assert the give-up path in milliseconds instead of seconds.
  final Duration saveWait;

  /// Marks the start of a new record and kicks off the location read without
  /// awaiting it. Call this at the moment the user asks for a new record, not
  /// when they save it.
  PendingCreationMeta begin() {
    // Guard the read here rather than in every caller: a throwing future that
    // nobody awaits until save time would surface as an unhandled async error
    // long after the frame that started it.
    Future<String?> guarded() async {
      try {
        return await _readLocation();
      } catch (e, st) {
        sdkLog('MobileCreationCapture: location read failed — $e\n$st');
        return null;
      }
    }

    return PendingCreationMeta._(
      startedAt: _now(),
      location: guarded(),
      defaultWait: saveWait,
    );
  }
}

/// A record's in-flight creation metadata: the timestamp is already known, the
/// location may still be arriving.
class PendingCreationMeta {
  PendingCreationMeta._({
    required this.startedAt,
    required Future<String?> location,
    required Duration defaultWait,
  }) : _location = location,
       _defaultWait = defaultWait;

  /// When the user asked for this record.
  final DateTime startedAt;

  final Future<String?> _location;
  final Duration _defaultWait;

  /// The captured location as a Frappe `Geolocation` value, or null when the
  /// read failed, was refused, or has not landed within [timeout].
  ///
  /// A timeout does not cancel the underlying read, so a later call — a child
  /// row saved after the fix arrives, for instance — can still return it.
  Future<String?> location({Duration? timeout}) async {
    final wait = timeout ?? _defaultWait;
    return _location.timeout(
      wait,
      onTimeout: () {
        sdkLog(
          'MobileCreationCapture: no location fix within '
          '${wait.inMilliseconds}ms — saving without one',
        );
        return null;
      },
    );
  }
}

/// Reads the device's current position and encodes it as a Frappe
/// `Geolocation` value, or returns null when it cannot be obtained.
///
/// Mirrors the fallback chain [GeolocationField] uses for its manual Fetch
/// Location button — live fix, then last known position — so an automatic
/// capture is no less likely to succeed than a hand-driven one. Unlike that
/// button this path is silent: there is no UI to show an error in, so every
/// refusal is logged and reported as "no location".
///
/// **Platform setup required by consuming apps:**
/// - Android: `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` in AndroidManifest.xml
/// - iOS: `NSLocationWhenInUseUsageDescription` in Info.plist
///
/// Neither is optional, and on iOS the omission is silent rather than loud:
/// `geolocator`'s `PermissionHandler` only calls `requestWhenInUseAuthorization`
/// when that key is present, and otherwise fails with
/// `PermissionDefinitionsNotFound` — which this capture path catches, logs and
/// reports as "no location", exactly as it would a refusal. An app missing the
/// key therefore records every `mobile_created_at` and no
/// `mobile_latitude_longitude` at all, with nothing but a log line to say why.
/// (An `NSLocationAlwaysUsageDescription` variant also satisfies geolocator, but
/// this capture is foreground-only and does not need it.)
Future<String?> readDeviceLocationAsGeoJson() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    sdkLog('MobileCreationCapture: location services disabled — skipping');
    return null;
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    sdkLog('MobileCreationCapture: location permission $permission — skipping');
    return null;
  }

  Position? position;
  try {
    position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 15),
      ),
    );
  } catch (e, st) {
    sdkLog(
      'MobileCreationCapture: getCurrentPosition failed — $e\n$st. '
      'Falling back to last known position.',
    );
    position = await Geolocator.getLastKnownPosition();
  }

  if (position == null) {
    sdkLog('MobileCreationCapture: no live or last-known position available');
    return null;
  }
  return geoJsonPoint(
    latitude: position.latitude,
    longitude: position.longitude,
  );
}
