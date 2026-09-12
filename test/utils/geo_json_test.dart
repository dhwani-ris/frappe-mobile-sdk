import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/geo_json.dart';

void main() {
  group('geoJsonPoint', () {
    test('emits the FeatureCollection shape Frappe stores', () {
      final decoded =
          jsonDecode(geoJsonPoint(latitude: 12.5, longitude: 77.25))
              as Map<String, dynamic>;

      expect(decoded['type'], 'FeatureCollection');
      final features = decoded['features'] as List;
      expect(features, hasLength(1));
      final feature = features.first as Map<String, dynamic>;
      expect(feature['type'], 'Feature');
      expect(feature['properties'], isEmpty);
      final geometry = feature['geometry'] as Map<String, dynamic>;
      expect(geometry['type'], 'Point');
    });

    test('orders coordinates [longitude, latitude], not the reverse', () {
      final decoded =
          jsonDecode(geoJsonPoint(latitude: 12.5, longitude: 77.25))
              as Map<String, dynamic>;
      final geometry =
          ((decoded['features'] as List).first
                  as Map<String, dynamic>)['geometry']
              as Map<String, dynamic>;

      expect(geometry['coordinates'], [77.25, 12.5]);
    });

    test('matches the shape GeolocationField already wrote', () {
      // Byte-for-byte the string _toGeoJson produced before it was extracted,
      // so values stored by earlier builds stay readable and vice versa.
      expect(
        geoJsonPoint(latitude: 12.5, longitude: 77.25),
        '{"type":"FeatureCollection","features":[{"type":"Feature",'
        '"geometry":{"type":"Point","coordinates":[77.25,12.5]},'
        '"properties":{}}]}',
      );
    });
  });

  group('parseGeoJsonPoint', () {
    test('round-trips an encoded point', () {
      final encoded = geoJsonPoint(latitude: -33.86, longitude: 151.21);
      expect(
        parseGeoJsonPoint(encoded),
        const GeoPoint(latitude: -33.86, longitude: 151.21),
      );
    });

    test('reads an already-decoded map', () {
      final decoded = jsonDecode(geoJsonPoint(latitude: 1.5, longitude: 2.5));
      expect(
        parseGeoJsonPoint(decoded),
        const GeoPoint(latitude: 1.5, longitude: 2.5),
      );
    });

    test('returns null for absent and blank values', () {
      expect(parseGeoJsonPoint(null), isNull);
      expect(parseGeoJsonPoint(''), isNull);
      expect(parseGeoJsonPoint('   '), isNull);
    });

    test('returns null rather than throwing on malformed input', () {
      expect(parseGeoJsonPoint('not json'), isNull);
      expect(parseGeoJsonPoint('{"features":[]}'), isNull);
      expect(parseGeoJsonPoint('{"features":[{"geometry":null}]}'), isNull);
      expect(
        parseGeoJsonPoint(
          '{"features":[{"geometry":{"type":"Polygon","coordinates":[]}}]}',
        ),
        isNull,
      );
      expect(
        parseGeoJsonPoint(
          '{"features":[{"geometry":{"type":"Point","coordinates":[1]}}]}',
        ),
        isNull,
      );
      expect(
        parseGeoJsonPoint(
          '{"features":[{"geometry":{"type":"Point","coordinates":["a","b"]}}]}',
        ),
        isNull,
      );
    });
  });
}
