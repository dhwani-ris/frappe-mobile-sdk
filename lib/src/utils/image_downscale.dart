import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'sdk_log.dart';

/// Size limit for photos taken or picked in an image field.
///
/// Off unless the host app sets [ImageUploadSettings.captureLimits]: Frappe
/// itself stores whatever the camera produced.
class ImageCaptureLimits {
  const ImageCaptureLimits({this.targetLongEdge = 1920, this.jpegQuality = 92});

  /// The long edge a shrunk photo keeps at least, in pixels. A photo is shrunk
  /// by the largest whole factor that keeps its long edge at or above this; a
  /// photo under twice this size is left as it is. With 1920 (Full HD), a
  /// 4000 px photo becomes 2000 px, a 6000 px photo 2000 px, and an 8 MP
  /// (3264 px) photo is not touched.
  final int targetLongEdge;

  /// JPEG quality (1-100) the shrunk photo is saved at.
  final int jpegQuality;
}

/// App-wide image upload policy. Every field and upload path reads it, so a
/// host sets it once at startup.
class ImageUploadSettings {
  ImageUploadSettings._();

  /// Shrink photos on the device before they are stored or uploaded. Null (the
  /// default) keeps Frappe's behaviour: the original file is uploaded.
  static ImageCaptureLimits? captureLimits;

  /// Ask the server to optimise uploaded images, the way Frappe Desk's uploader
  /// does by default: an image over 200 KB that is not an SVG is sent with
  /// `optimize`, and the server stores a copy fitted into 1024x768 at quality
  /// 85. False (the default) uploads the file as it is, which is what Frappe's
  /// `upload_file` API does when the client does not ask.
  ///
  /// Do not combine with [captureLimits]: the server's resize ignores the EXIF
  /// rotation, so a portrait photo already turned upright on the device is cut
  /// to 512x768.
  static bool serverOptimize = false;

  /// Restores the defaults (for tests).
  static void reset() {
    captureLimits = null;
    serverOptimize = false;
  }
}

/// Width and height stored in a JPEG's frame header, read without decoding
/// any image data. Null when [bytes] is not a JPEG or has no frame header.
///
/// These are the stored dimensions: a camera that saves a portrait photo as
/// landscape pixels plus an EXIF rotation reports the landscape size here.
@visibleForTesting
({int width, int height})? jpegDimensions(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  var i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final marker = bytes[i + 1];
    // Fill bytes before a marker.
    if (marker == 0xFF) {
      i++;
      continue;
    }
    // Markers without a length field.
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2;
      continue;
    }
    // Start of scan or end of image before any frame header.
    if (marker == 0xDA || marker == 0xD9) return null;
    final length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (length < 2) return null;
    // SOF0-SOF15, except DHT (C4), JPG (C8) and DAC (CC).
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (i + 8 >= bytes.length) return null;
      final height = (bytes[i + 5] << 8) | bytes[i + 6];
      final width = (bytes[i + 7] << 8) | bytes[i + 8];
      if (width == 0 || height == 0) return null;
      return (width: width, height: height);
    }
    i += 2 + length;
  }
  return null;
}

/// Returns [file] shrunk per [limits], or [file] itself when it is under
/// twice [ImageCaptureLimits.targetLongEdge], is not a JPEG, cannot be read,
/// or would not get smaller.
///
/// - The size is read from the JPEG header first, so a photo that stays as it
///   is is never decoded.
/// - The photo is shrunk by a whole-number factor k. Flutter's image decoder
///   does the work: it decodes the JPEG straight at the reduced size (for
///   k = 2, 4 or 8 that is the JPEG format's own exact scaling), so the
///   full-size photo is never held in memory. Measured on a 12 MP photo (desktop,
///   debug build): about half the peak memory of decoding it in Dart, and a
///   third of the time.
/// - The decoder applies the camera's rotation (EXIF orientation), so the
///   result is upright and its orientation tag is reset. Other EXIF, such as
///   time and GPS, is copied across.
/// - The result keeps the original file name, in a new folder next to it.
///
/// Uses `dart:ui`, so it runs on the UI isolate; the decode itself happens off
/// the UI thread, and the JPEG encode runs on a background isolate.
Future<File> downscalePickedImage(File file, ImageCaptureLimits limits) async {
  try {
    return await _downscale(file, limits) ?? file;
  } catch (e, st) {
    sdkLog('downscalePickedImage: kept the original — $e\n$st');
    return file;
  }
}

Future<File?> _downscale(File file, ImageCaptureLimits limits) async {
  final path = file.path;
  final ext = p.extension(path).toLowerCase();
  if (ext != '.jpg' && ext != '.jpeg') return null;
  final bytes = await file.readAsBytes();
  final stored = jpegDimensions(bytes);
  if (stored == null) return null;

  final exif = img.decodeJpgExif(bytes);
  // Orientations 5-8 turn the photo by 90 degrees, swapping its axes.
  final turned = (exif?.imageIfd.orientation ?? 1) >= 5;
  final w = turned ? stored.height : stored.width;
  final h = turned ? stored.width : stored.height;
  final longEdge = w > h ? w : h;
  // Largest whole factor that keeps the long edge at or above the target.
  final k = longEdge ~/ limits.targetLongEdge;
  if (k < 2) return null;

  // Rounded up, which is the size the JPEG's own 1/2, 1/4 and 1/8 scaling
  // produces, so the decoder does not resample a second time.
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: (w + k - 1) ~/ k,
    targetHeight: (h + k - 1) ~/ k,
  );
  final int outW;
  final int outH;
  final ByteData rgba;
  try {
    final image = (await codec.getNextFrame()).image;
    try {
      outW = image.width;
      outH = image.height;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      rgba = data;
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }

  final quality = limits.jpegQuality;
  final pixels = TransferableTypedData.fromList([rgba.buffer.asUint8List()]);
  final encoded = await Isolate.run(() {
    final small = img.Image.fromBytes(
      width: outW,
      height: outH,
      bytes: pixels.materialize(),
      numChannels: 4,
    );
    if (exif != null) {
      small.exif = exif;
      // The pixels are upright now.
      if (small.exif.imageIfd.hasOrientation) {
        small.exif.imageIfd.orientation = 1;
      }
    }
    return img.encodeJpg(small, quality: quality);
  });
  if (encoded.length >= bytes.length) return null;

  // Same name as the original: it is what reaches the server.
  final folder = await Directory(p.dirname(path)).createTemp('downscaled_');
  final out = File(p.join(folder.path, p.basename(path)));
  await out.writeAsBytes(encoded, flush: true);
  return out;
}

/// What an image field runs on every picked or captured photo: shrinks it when
/// the host app set [ImageUploadSettings.captureLimits], otherwise returns it
/// unchanged (Frappe behaviour). Runs before the photo is staged or uploaded,
/// so online and offline uploads both get the smaller file.
Future<File> preparePickedImage(File picked) {
  final limits = ImageUploadSettings.captureLimits;
  if (limits == null) return Future.value(picked);
  return downscalePickedImage(picked, limits);
}
