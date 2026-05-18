// Covers GeolocationField's visible-state surface and the existing-value parse
// path. The actual `_fetchLocation` flow goes through the geolocator platform
// channel, which is not available in widget-test mode; integration tests on a
// device cover that branch.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/geolocation_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
  ValueChanged<dynamic>? onChanged,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: GeolocationField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
        ),
      ),
    ),
  );
}

String _geoJson(double lat, double lng) => jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    {
      'type': 'Feature',
      'geometry': {
        'type': 'Point',
        'coordinates': [lng, lat],
      },
      'properties': {},
    },
  ],
});

void main() {
  final field = DocField(
    fieldname: 'loc',
    fieldtype: 'Geolocation',
    label: 'Location',
  );

  testWidgets('empty value shows the "Fetch Location" button', (tester) async {
    await _pump(tester, field: field);
    expect(find.text('Fetch Location'), findsOneWidget);
    expect(find.text('Location captured'), findsNothing);
  });

  testWidgets('parses GeoJSON value and shows captured coordinates', (
    tester,
  ) async {
    await _pump(tester, field: field, value: _geoJson(12.345678, 76.123456));
    expect(find.text('12.345678, 76.123456'), findsOneWidget);
    expect(find.text('Location captured'), findsOneWidget);
    expect(find.text('Refresh Location'), findsOneWidget);
  });

  testWidgets('parsing a Map directly works too', (tester) async {
    await _pump(
      tester,
      field: field,
      value: {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [40.0, -3.0],
            },
            'properties': {},
          },
        ],
      },
    );
    expect(find.text('-3.000000, 40.000000'), findsOneWidget);
  });

  testWidgets('malformed value falls back to empty state without crash', (
    tester,
  ) async {
    await _pump(tester, field: field, value: '{not json');
    expect(find.text('Fetch Location'), findsOneWidget);
  });

  testWidgets('clear button (X) flips state back to empty and emits null', (
    tester,
  ) async {
    Object? emitted = 'sentinel';
    await _pump(
      tester,
      field: field,
      value: _geoJson(1.0, 2.0),
      onChanged: (v) => emitted = v,
    );
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(emitted, isNull);
    expect(find.text('Fetch Location'), findsOneWidget);
  });

  testWidgets('readOnly hides Fetch button + clear icon', (tester) async {
    await _pump(
      tester,
      field: field,
      value: _geoJson(1.0, 2.0),
      enabled: false,
    );
    expect(find.text('Fetch Location'), findsNothing);
    expect(find.text('Refresh Location'), findsNothing);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('readOnly + empty shows "No location captured" placeholder', (
    tester,
  ) async {
    await _pump(tester, field: field, enabled: false);
    expect(find.text('No location captured'), findsOneWidget);
  });
}
