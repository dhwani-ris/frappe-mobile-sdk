import 'dart:convert';

import 'sdk_log.dart';

/// A decoded latitude/longitude pair.
class GeoPoint {
  const GeoPoint({required this.latitude, required this.longitude});

  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      other is GeoPoint &&
      other.latitude == latitude &&
      other.longitude == longitude;

  @override
  int get hashCode => Object.hash(latitude, longitude);

  @override
  String toString() => 'GeoPoint($latitude, $longitude)';
}

/// Encodes a single coordinate as the GeoJSON `FeatureCollection` string a
/// Frappe `Geolocation` field stores.
///
/// Note the axis order: GeoJSON coordinates are `[longitude, latitude]`, the
/// reverse of how they are spoken and of this function's parameter order.
/// Shared by every producer of a Geolocation value in the SDK so the
/// hand-drawn `GeolocationField` and the automatic capture written at
/// new-record time cannot drift into two different shapes — if they did,
/// [parseGeoJsonPoint] would fail to read one of them back and the field
/// would render blank over a value that is actually present.
String geoJsonPoint({required double latitude, required double longitude}) {
  return jsonEncode({
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [longitude, latitude],
        },
        'properties': <String, dynamic>{},
      },
    ],
  });
}

/// Reads the first `Point` feature out of a Frappe `Geolocation` value, or
/// null when [value] is empty, malformed, or holds no point geometry.
///
/// Accepts both a decoded map and the encoded string, because a Geolocation
/// value reaches the SDK as a String from SQLite and the server but as a Map
/// from a form field that has not been serialized yet. Never throws: a
/// malformed value is indistinguishable from an absent one for every caller.
GeoPoint? parseGeoJsonPoint(dynamic value) {
  if (value == null) return null;
  if (value is! Map && value.toString().trim().isEmpty) return null;
  try {
    final geo = value is Map
        ? Map<String, dynamic>.from(value)
        : jsonDecode(value.toString()) as Map<String, dynamic>;
    final features = geo['features'];
    if (features is! List || features.isEmpty) return null;
    final first = features.first;
    if (first is! Map) return null;
    final geometry = first['geometry'];
    if (geometry is! Map || geometry['type'] != 'Point') return null;
    final coords = geometry['coordinates'];
    if (coords is! List || coords.length < 2) return null;
    final lng = coords[0];
    final lat = coords[1];
    if (lng is! num || lat is! num) return null;
    return GeoPoint(latitude: lat.toDouble(), longitude: lng.toDouble());
  } catch (e, st) {
    // A malformed stored value must not break a form render or a save, but it
    // must not vanish silently either — a value that is present yet unreadable
    // is a data problem worth seeing in the log.
    sdkLog('parseGeoJsonPoint: unreadable Geolocation value — $e\n$st');
    return null;
  }
}
