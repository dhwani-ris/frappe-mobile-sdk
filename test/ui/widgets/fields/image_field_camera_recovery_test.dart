// Covers the identity that scopes image_picker's app-wide lost-data cache back
// to the field that actually launched the interrupted capture.
//
// The surrounding recovery flow (marker file in the cache dir + Android's
// activity-kill stash + retrieveLostData) is Android-only and cannot be
// exercised off-device: it is gated on Platform.isAndroid, and the platform
// stash only exists after the OS kills the host activity mid-capture. Only the
// key derivation is unit-testable here; the end-to-end behaviour needs a device.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';

void main() {
  test('different fields get different capture keys', () {
    final a = cameraCaptureMarkerKey(
      DocField(fieldname: 'front_photo', fieldtype: 'Attach Image'),
    );
    final b = cameraCaptureMarkerKey(
      DocField(fieldname: 'back_photo', fieldtype: 'Attach Image'),
    );
    expect(a, isNot(b));
  });

  test('the same field definition always yields the same key', () {
    expect(
      cameraCaptureMarkerKey(
        DocField(fieldname: 'front_photo', fieldtype: 'Attach Image'),
      ),
      cameraCaptureMarkerKey(
        DocField(fieldname: 'front_photo', fieldtype: 'Attach Image'),
      ),
    );
  });

  test('fieldtype participates in the key', () {
    expect(
      cameraCaptureMarkerKey(DocField(fieldname: 'photo', fieldtype: 'Image')),
      isNot(
        cameraCaptureMarkerKey(
          DocField(fieldname: 'photo', fieldtype: 'Attach Image'),
        ),
      ),
    );
  });

  test('a null fieldname is tolerated and stays distinct', () {
    final anonymous = cameraCaptureMarkerKey(DocField(fieldtype: 'Image'));
    expect(anonymous, isNotEmpty);
    expect(
      anonymous,
      isNot(
        cameraCaptureMarkerKey(
          DocField(fieldname: 'photo', fieldtype: 'Image'),
        ),
      ),
    );
  });

  test('KNOWN LIMITATION: same fieldname in two forms shares one key', () {
    // DocField carries no owning doctype or child-row identifier, so two
    // ImageFields that share a fieldname collapse to the same key and can still
    // cross-claim a recovered photo. This asserts the limitation on purpose: if
    // an owner identifier is ever added to DocField, this test should fail and
    // be tightened.
    expect(
      cameraCaptureMarkerKey(DocField(fieldname: 'photo', fieldtype: 'Image')),
      cameraCaptureMarkerKey(DocField(fieldname: 'photo', fieldtype: 'Image')),
    );
  });
}
