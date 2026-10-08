import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/image_downscale.dart';
import 'package:image/image.dart' as img;

/// The opt-in photo size limit (ImageUploadSettings.captureLimits). Off by
/// default: Frappe stores what the camera produced. When a host app turns it
/// on, a picked photo is shrunk on the device before it is staged or
/// uploaded, without visibly lowering its quality.
void main() {
  // The shrink decodes with Flutter's image decoder (dart:ui).
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('downscale-');
  });

  tearDown(() async {
    ImageUploadSettings.reset();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<File> jpeg(
    String name,
    int w,
    int h, {
    int quality = 95,
    void Function(img.Image)? paint,
    int? orientation,
  }) async {
    final image = img.Image(width: w, height: h);
    if (paint != null) {
      paint(image);
    } else {
      // Smooth content with some detail, like a photo.
      for (final p in image) {
        p
          ..r = (p.x * 255 ~/ w)
          ..g = (p.y * 255 ~/ h)
          ..b = ((p.x + p.y) % 256);
      }
    }
    if (orientation != null) image.exif.imageIfd.orientation = orientation;
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(img.encodeJpg(image, quality: quality));
    return f;
  }

  img.Image read(File f) => img.decodeJpg(f.readAsBytesSync())!;

  const limits = ImageCaptureLimits();

  test('defaults: never below Full HD on the long edge, JPEG quality 92', () {
    // Measured on full-size camera photos (market, landscape, signboard,
    // handwritten page): a 2x shrink at q92 scores SSIM 0.985-0.997 against
    // the original at phone viewing size; a 3x shrink drops to 0.92-0.95.
    const d = ImageCaptureLimits();
    expect(d.targetLongEdge, 1920);
    expect(d.jpegQuality, 92);
  });

  test('off by default: no limits, Frappe behaviour', () {
    expect(ImageUploadSettings.captureLimits, isNull);
    expect(ImageUploadSettings.serverOptimize, isFalse);
  });

  test(
    'a 12 MP photo is halved (largest whole factor keeping >= 1920 px)',
    () async {
      // Whole-number factors only, so the JPEG's own 1/2 scaling does the
      // work and nothing is resampled at an awkward fraction.
      final src = await jpeg('land.jpg', 4000, 3000);
      final out = await downscalePickedImage(src, limits);
      expect(out.path, isNot(src.path));
      expect(src.existsSync(), isTrue, reason: 'the original is left alone');
      final o = read(out);
      expect([o.width, o.height], [2000, 1500]);
      expect(out.lengthSync(), lessThan(src.lengthSync()));
    },
  );

  test('a much larger photo uses a larger factor', () async {
    // 6000 / 1920 allows a factor of 3 (2000 px); sizes round up.
    final o = read(
      await downscalePickedImage(await jpeg('big.jpg', 6000, 4000), limits),
    );
    expect([o.width, o.height], [2000, 1334]);
  });

  test('a portrait photo keeps its aspect ratio', () async {
    final src = await jpeg('port.jpg', 3000, 4000);
    final o = read(await downscalePickedImage(src, limits));
    expect([o.width, o.height], [1500, 2000]);
  });

  test(
    'a photo under twice the target is left untouched (e.g. 8 MP)',
    () async {
      // Halving 3264 px would give 1632 px, below Full HD, so it stays as is.
      final src = await jpeg('eight_mp.jpg', 3264, 2448);
      final before = src.readAsBytesSync();
      final out = await downscalePickedImage(src, limits);
      expect(out.path, src.path);
      expect(out.readAsBytesSync(), before);
    },
  );

  test('downscaling averages pixels, so fine detail does not alias', () async {
    // 1-px black/white stripes. Averaging gives an even mid grey; dropping
    // pixels (nearest neighbour, as the platform picker's resize does) leaves
    // hard stripes or a moire pattern.
    final src = await jpeg(
      'stripes.jpg',
      4000,
      3000,
      quality: 100,
      paint: (i) {
        for (final p in i) {
          final v = p.x.isEven ? 0 : 255;
          p
            ..r = v
            ..g = v
            ..b = v;
        }
      },
    );
    final o = read(await downscalePickedImage(src, limits));
    final values = <num>[];
    for (var y = 100; y < 1400; y += 97) {
      for (var x = 100; x < 1900; x += 3) {
        values.add(o.getPixel(x, y).r);
      }
    }
    final mean = values.reduce((a, b) => a + b) / values.length;
    final sd = math.sqrt(
      values.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
          values.length,
    );
    expect(mean, closeTo(127.5, 6));
    expect(sd, lessThan(6));
  });

  test('camera rotation (EXIF orientation) is applied, not lost', () async {
    // Stored 4000x3000 with "rotate 90" = shown as a 3000x4000 portrait. The
    // stored left half is red, so the upright photo's TOP half is red.
    final src = await jpeg(
      'rot.jpg',
      4000,
      3000,
      orientation: 6,
      paint: (i) {
        for (final p in i) {
          p
            ..r = p.x < 2000 ? 255 : 0
            ..g = 0
            ..b = p.x < 2000 ? 0 : 255;
        }
      },
    );
    final o = read(await downscalePickedImage(src, limits));
    expect([o.width, o.height], [1500, 2000]);
    expect(o.getPixel(750, 400).r, greaterThan(200), reason: 'top is red');
    expect(o.getPixel(750, 1600).b, greaterThan(200), reason: 'bottom blue');
    expect(
      !o.exif.imageIfd.hasOrientation || o.exif.imageIfd.orientation == 1,
      isTrue,
    );
  });

  test('other EXIF (e.g. GPS) is kept', () async {
    final src = await jpeg(
      'gps.jpg',
      4000,
      3000,
      paint: (i) {
        i.exif.gpsIfd['GPSLatitudeRef'] = img.IfdValueAscii('N');
      },
    );
    final o = read(await downscalePickedImage(src, limits));
    expect(o.exif.gpsIfd['GPSLatitudeRef']?.toString(), 'N');
  });

  test('not a JPEG, or unreadable: the original is used', () async {
    final png = File('${dir.path}/shot.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 4000, height: 3000)));
    expect((await downscalePickedImage(png, limits)).path, png.path);

    final junk = File('${dir.path}/broken.jpg')
      ..writeAsBytesSync(List<int>.filled(5000, 1));
    expect((await downscalePickedImage(junk, limits)).path, junk.path);
  });

  test(
    'if shrinking would not make the file smaller, the original is kept',
    () async {
      // Noise saved at very low quality is already small; re-encoding the
      // shrunk noise at high quality is bigger, so the original wins.
      final rnd = math.Random(1);
      final src = await jpeg(
        'noise.jpg',
        4000,
        3000,
        quality: 3,
        paint: (i) {
          for (final p in i) {
            p
              ..r = rnd.nextInt(256)
              ..g = rnd.nextInt(256)
              ..b = rnd.nextInt(256);
          }
        },
      );
      expect((await downscalePickedImage(src, limits)).path, src.path);
    },
  );

  test('the shrunk photo keeps the original file name', () async {
    // The name is what the server stores; a `_2000px` suffix leaked into it.
    for (final name in ['IMG_123.jpg', 'scan.JPEG']) {
      final src = await jpeg(name, 4000, 3000);
      final out = await downscalePickedImage(src, limits);
      expect(out.path, isNot(src.path));
      expect(out.uri.pathSegments.last, name);
    }
  });

  group('jpegDimensions reads the frame header only', () {
    test('baseline JPEG, including one with EXIF before the frame', () async {
      final plain = await jpeg('a.jpg', 640, 480);
      expect(jpegDimensions(plain.readAsBytesSync()), (
        width: 640,
        height: 480,
      ));
      final tagged = await jpeg('b.jpg', 640, 480, orientation: 6);
      expect(
        jpegDimensions(tagged.readAsBytesSync()),
        (width: 640, height: 480),
        reason: 'stored size; the rotation is applied later',
      );
    });

    test('not a JPEG, or cut short: null', () {
      expect(jpegDimensions(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
      expect(jpegDimensions(Uint8List.fromList([0xFF, 0xD8, 0xFF])), isNull);
      final png = img.encodePng(img.Image(width: 8, height: 8));
      expect(jpegDimensions(png), isNull);
    });
  });

  group('preparePickedImage (what ImageField runs on every pick)', () {
    test('with no limits set, the picked file is used as is', () async {
      final src = await jpeg('cam.jpg', 4000, 3000);
      expect((await preparePickedImage(src)).path, src.path);
    });

    test('with limits set, the picked photo is shrunk', () async {
      ImageUploadSettings.captureLimits = const ImageCaptureLimits();
      final src = await jpeg('cam.jpg', 4000, 3000);
      final o = read(await preparePickedImage(src));
      expect([o.width, o.height], [2000, 1500]);
    });
  });
}
