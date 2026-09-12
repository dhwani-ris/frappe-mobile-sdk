import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/utils/mobile_creation_stamp.dart';

/// A doctype provisioned by mobile_control: both Custom Fields present,
/// hidden and read-only exactly as `_MOBILE_CUSTOM_FIELDS` declares them.
DocTypeMeta _provisioned() => DocTypeMeta(
  name: 'Household Survey',
  fields: [
    DocField(
      fieldname: mobileCreatedAtField,
      fieldtype: 'Datetime',
      hidden: true,
      readOnly: true,
    ),
    DocField(
      fieldname: mobileLatitudeLongitudeField,
      fieldtype: 'Geolocation',
      hidden: true,
      readOnly: true,
    ),
    DocField(fieldname: 'village', fieldtype: 'Data'),
  ],
);

/// A doctype on a server without mobile_control's custom fields.
DocTypeMeta _bare() => DocTypeMeta(
  name: 'Household Survey',
  fields: [DocField(fieldname: 'village', fieldtype: 'Data')],
);

void main() {
  group('formatFrappeDatetime', () {
    test('emits naive space-separated seconds precision', () {
      expect(
        formatFrappeDatetime(DateTime(2026, 8, 18, 9, 5, 3)),
        '2026-08-18 09:05:03',
      );
    });

    test('never emits the ISO T separator or a Z suffix', () {
      final s = formatFrappeDatetime(DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(s, isNot(contains('T')));
      expect(s, isNot(contains('Z')));
      expect(s, '2026-01-02 03:04:05');
    });
  });

  group('stampCreationMeta', () {
    test('writes both stamps when the meta declares them', () {
      final out = stampCreationMeta(
        meta: _provisioned(),
        data: {'village': 'Rampur'},
        createdAt: '2026-08-18 09:05:03',
        latitudeLongitude: '{"type":"FeatureCollection"}',
      );

      expect(out[mobileCreatedAtField], '2026-08-18 09:05:03');
      expect(out[mobileLatitudeLongitudeField], '{"type":"FeatureCollection"}');
      expect(out['village'], 'Rampur', reason: 'must not disturb form data');
    });

    test('writes nothing when the meta does not declare the fields', () {
      final out = stampCreationMeta(
        meta: _bare(),
        data: {'village': 'Rampur'},
        createdAt: '2026-08-18 09:05:03',
        latitudeLongitude: '{"type":"FeatureCollection"}',
      );

      expect(out.containsKey(mobileCreatedAtField), isFalse);
      expect(out.containsKey(mobileLatitudeLongitudeField), isFalse);
      expect(out, {'village': 'Rampur'});
    });

    test('never overwrites an existing stamp', () {
      final out = stampCreationMeta(
        meta: _provisioned(),
        data: {
          mobileCreatedAtField: '2026-01-01 00:00:00',
          mobileLatitudeLongitudeField: 'original',
        },
        createdAt: '2026-08-18 09:05:03',
        latitudeLongitude: 'fresh',
      );

      expect(out[mobileCreatedAtField], '2026-01-01 00:00:00');
      expect(out[mobileLatitudeLongitudeField], 'original');
    });

    test('treats a blank existing value as absent and fills it', () {
      final out = stampCreationMeta(
        meta: _provisioned(),
        data: {mobileCreatedAtField: '   ', mobileLatitudeLongitudeField: ''},
        createdAt: '2026-08-18 09:05:03',
        latitudeLongitude: 'fresh',
      );

      expect(out[mobileCreatedAtField], '2026-08-18 09:05:03');
      expect(out[mobileLatitudeLongitudeField], 'fresh');
    });

    test('a null location still lets the timestamp through', () {
      final out = stampCreationMeta(
        meta: _provisioned(),
        data: {},
        createdAt: '2026-08-18 09:05:03',
        latitudeLongitude: null,
      );

      expect(out[mobileCreatedAtField], '2026-08-18 09:05:03');
      expect(out.containsKey(mobileLatitudeLongitudeField), isFalse);
    });

    test('both null is a no-op', () {
      final out = stampCreationMeta(
        meta: _provisioned(),
        data: {'village': 'Rampur'},
      );
      expect(out, {'village': 'Rampur'});
    });

    test('does not mutate the input map', () {
      final input = <String, dynamic>{'village': 'Rampur'};
      stampCreationMeta(
        meta: _provisioned(),
        data: input,
        createdAt: '2026-08-18 09:05:03',
      );
      expect(input, {'village': 'Rampur'});
    });
  });
}
