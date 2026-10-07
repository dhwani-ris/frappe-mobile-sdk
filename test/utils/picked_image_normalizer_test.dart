import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/picked_image_normalizer.dart';
import 'package:path/path.dart' as p;

/// A JPEG skeleton: SOI, APP0 (JFIF), the given extra segments, DQT, SOS +
/// scan bytes, EOI. Not decodable, but structurally what the stripper walks.
Uint8List _jpeg(List<List<int>> extraSegments) {
  List<int> seg(int marker, List<int> payload) => [
    0xFF,
    marker,
    (payload.length + 2) >> 8,
    (payload.length + 2) & 0xFF,
    ...payload,
  ];
  return Uint8List.fromList([
    0xFF, 0xD8,
    ...seg(0xE0, [0x4A, 0x46, 0x49, 0x46, 0x00, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
    for (final s in extraSegments) ...s,
    ...seg(0xDB, List<int>.filled(65, 7)),
    0xFF, 0xDA, 0x00, 0x04, 0x01, 0x02, // SOS header
    0x11, 0x22, 0xFF, 0x00, 0x33, // entropy data (with a stuffed FF00)
    0xFF, 0xD9,
  ]);
}

/// An APP1 Exif segment with Orientation=[orientation] plus a fake GPS tag.
List<int> _exifApp1(int orientation, {bool littleEndian = false}) {
  List<int> u16(int v) =>
      littleEndian ? [v & 0xFF, v >> 8] : [v >> 8, v & 0xFF];
  List<int> u32(int v) => littleEndian
      ? [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24]
      : [v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  final tiff = <int>[
    ...(littleEndian ? [0x49, 0x49] : [0x4D, 0x4D]),
    ...u16(42),
    ...u32(8),
    ...u16(2),
    ...u16(0x0112), ...u16(3), ...u32(1), ...u16(orientation), 0, 0,
    ...u16(0x8825), ...u16(4), ...u32(1), ...u32(1234), // GPS IFD pointer
    ...u32(0),
  ];
  final payload = [0x45, 0x78, 0x69, 0x66, 0, 0, ...tiff];
  return [
    0xFF,
    0xE1,
    (payload.length + 2) >> 8,
    (payload.length + 2) & 0xFF,
    ...payload,
  ];
}

List<int> _comment(String s) {
  final b = s.codeUnits;
  return [0xFF, 0xFE, (b.length + 2) >> 8, (b.length + 2) & 0xFF, ...b];
}

List<int> _icc() {
  final b = 'ICC_PROFILE\u0000'.codeUnits + List<int>.filled(20, 9);
  return [0xFF, 0xE2, (b.length + 2) >> 8, (b.length + 2) & 0xFF, ...b];
}

bool _contains(Uint8List hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  group('stripJpegMetadata', () {
    test('drops Exif/comment segments but keeps the orientation', () {
      final src = _jpeg([_exifApp1(6), _comment('Samsung SM-A515F')]);
      final out = stripJpegMetadata(src);

      expect(out.sublist(0, 2), [0xFF, 0xD8]);
      expect(_contains(out, 'Samsung'.codeUnits), isFalse);
      expect(_contains(out, [0x88, 0x25]), isFalse, reason: 'GPS pointer gone');
      expect(readJpegOrientation(out), 6);
      // The scan data and EOI survive byte-for-byte.
      expect(out.sublist(out.length - 7), [
        0x11,
        0x22,
        0xFF,
        0x00,
        0x33,
        0xFF,
        0xD9,
      ]);
      expect(out.length, lessThan(src.length));
    });

    test('reads little-endian Exif too', () {
      final out = stripJpegMetadata(_jpeg([_exifApp1(8, littleEndian: true)]));
      expect(readJpegOrientation(out), 8);
    });

    test('writes no Exif at all for the default orientation', () {
      final out = stripJpegMetadata(_jpeg([_exifApp1(1)]));
      expect(_contains(out, 'Exif'.codeUnits), isFalse);
      expect(readJpegOrientation(out), 1);
    });

    test('keeps the ICC colour profile', () {
      final out = stripJpegMetadata(_jpeg([_icc(), _exifApp1(3)]));
      expect(_contains(out, 'ICC_PROFILE'.codeUnits), isTrue);
    });

    test('returns malformed input unchanged rather than corrupting it', () {
      final bad = Uint8List.fromList([0xFF, 0xD8, 0x12, 0x34, 0x56]);
      expect(stripJpegMetadata(bad), bad);
    });
  });

  group('sniffImageFormat', () {
    test('recognises JPEG, HEIC brands and others', () {
      expect(sniffImageFormat(_jpeg(const [])), PickedImageFormat.jpeg);
      for (final brand in ['heic', 'heix', 'mif1', 'msf1', 'hevc']) {
        final b = Uint8List.fromList([
          0,
          0,
          0,
          0x18,
          ...'ftyp'.codeUnits,
          ...brand.codeUnits,
          0,
          0,
          0,
          0,
        ]);
        expect(sniffImageFormat(b), PickedImageFormat.heic, reason: brand);
      }
      expect(
        sniffImageFormat(
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        PickedImageFormat.other,
      );
    });
  });

  group('normalizePickedImage', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('norm'));
    tearDown(() async => dir.delete(recursive: true));

    test(
      'a re-encoded HEIC (JPEG bytes, .heic name) becomes a stripped .jpg',
      () async {
        final f = File(p.join(dir.path, 'scaled_IMG_2041.heic'))
          ..writeAsBytesSync(_jpeg([_exifApp1(6), _comment('gps')]));
        final out = await normalizePickedImage(f);

        expect(p.basename(out.path), 'IMG_2041.jpg');
        final bytes = out.readAsBytesSync();
        expect(_contains(bytes, 'gps'.codeUnits), isFalse);
        expect(readJpegOrientation(bytes), 6);
      },
    );

    test('a camera .jpg keeps its name', () async {
      final f = File(p.join(dir.path, '335086.jpg'))
        ..writeAsBytesSync(_jpeg(const []));
      final out = await normalizePickedImage(f);
      expect(p.basename(out.path), '335086.jpg');
    });

    test('HEIC bytes that could not be converted are refused', () async {
      final f = File(
        p.join(dir.path, 'IMG_1.heic'),
      )..writeAsBytesSync([0, 0, 0, 0x18, ...'ftypheic'.codeUnits, 0, 0, 0, 0]);
      await expectLater(
        normalizePickedImage(f),
        throwsA(isA<UnsupportedImageFormatException>()),
      );
    });

    test('HEIC bytes hiding behind a .jpg name are refused too', () async {
      final f = File(
        p.join(dir.path, 'cam.jpg'),
      )..writeAsBytesSync([0, 0, 0, 0x18, ...'ftypmif1'.codeUnits, 0, 0, 0, 0]);
      await expectLater(
        normalizePickedImage(f),
        throwsA(isA<UnsupportedImageFormatException>()),
      );
    });

    test('a PNG passes through untouched', () async {
      final f = File(p.join(dir.path, 'shot.png'))
        ..writeAsBytesSync([
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          1,
          2,
          3,
          4,
        ]);
      final out = await normalizePickedImage(f);
      expect(out.path, f.path);
    });
  });
}
