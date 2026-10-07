import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'sdk_log.dart';

/// JPEG quality `ImageField` asks the picker to re-encode at.
///
/// Any value below 100 (or a max dimension) is what makes image_picker decode
/// and re-encode the pick as JPEG at all. Without it a gallery pick is the
/// ORIGINAL file, which on most current Samsung / Xiaomi / iPhone-sourced
/// photos is HEIC, and Frappe rejects that by extension (`FileTypeNotAllowed`).
const int kPickedImageQuality = 85;

/// Longest side, in pixels, `ImageField` asks the picker to downscale to.
const double kPickedImageMaxDimension = 2048;

/// Thrown when a picked image is in a format the server will not accept and
/// the device could not convert it (HEIC on Android 8 and older, whose
/// BitmapFactory cannot decode it, so image_picker hands back the original).
class UnsupportedImageFormatException implements Exception {
  final String path;
  const UnsupportedImageFormatException(this.path);

  @override
  String toString() =>
      'UnsupportedImageFormatException: $path is HEIC, which the server '
      'does not accept';
}

/// What a picked file's bytes actually are, whatever its name says.
enum PickedImageFormat { jpeg, heic, other }

/// HEIF/HEIC major brands (`ftyp` box) phones write.
const Set<String> _heifBrands = {
  'heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1', //
};

PickedImageFormat sniffImageFormat(Uint8List b) {
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return PickedImageFormat.jpeg;
  }
  if (b.length >= 12 && String.fromCharCodes(b.sublist(4, 8)) == 'ftyp') {
    if (_heifBrands.contains(String.fromCharCodes(b.sublist(8, 12)))) {
      return PickedImageFormat.heic;
    }
  }
  return PickedImageFormat.other;
}

/// Makes a just-picked image safe to stage and upload.
///
/// * JPEG bytes: metadata stripped (see [stripJpegMetadata]) and the name
///   given a `.jpg` extension. image_picker keeps the ORIGINAL name on the
///   file it re-encodes (`scaled_IMG_2041.heic` holding JPEG bytes), and the
///   server checks the extension, so the bytes alone being JPEG is not enough.
/// * HEIC bytes: refused with [UnsupportedImageFormatException] — the picker
///   could not convert it, and uploading it is guaranteed to be rejected.
/// * Anything else (PNG, WebP): returned untouched.
///
/// The result is written to a fresh directory beside [picked], never over it,
/// so the caller can delete that directory once the file is staged. Never
/// fails on its own account: if rewriting fails the original is returned.
Future<File> normalizePickedImage(File picked) async {
  final Uint8List bytes;
  try {
    bytes = await picked.readAsBytes();
  } catch (e, st) {
    sdkLog('normalizePickedImage: could not read ${picked.path} — $e\n$st');
    return picked;
  }
  switch (sniffImageFormat(bytes)) {
    case PickedImageFormat.heic:
      throw UnsupportedImageFormatException(picked.path);
    case PickedImageFormat.other:
      return picked;
    case PickedImageFormat.jpeg:
      break;
  }
  var stem = p.basenameWithoutExtension(picked.path);
  if (stem.startsWith('scaled_') && stem.length > 'scaled_'.length) {
    stem = stem.substring('scaled_'.length);
  }
  try {
    final dir = await picked.parent.createTemp('normalized_');
    final out = File(p.join(dir.path, '$stem.jpg'));
    await out.writeAsBytes(stripJpegMetadata(bytes), flush: true);
    return out;
  } catch (e, st) {
    sdkLog('normalizePickedImage: rewrite failed for ${picked.path} — $e\n$st');
    return picked;
  }
}

/// Deletes the directory [normalizePickedImage] created for [normalized], if
/// it created one. Best-effort.
Future<void> discardNormalizedImage(File original, File normalized) async {
  if (normalized.path == original.path) return;
  try {
    final dir = normalized.parent;
    if (p.basename(dir.path).startsWith('normalized_') && await dir.exists()) {
      await dir.delete(recursive: true);
    }
  } catch (e, st) {
    sdkLog('discardNormalizedImage(${normalized.path}) failed — $e\n$st');
  }
}

/// Removes every metadata segment from a JPEG except what rendering needs.
///
/// Dropped: Exif (GPS, device make/model, timestamps, maker notes, embedded
/// thumbnail), XMP, comments and other APPn blocks. Kept: JFIF (APP0), the ICC
/// colour profile (APP2 `ICC_PROFILE`) and every image segment.
///
/// The Exif ORIENTATION is carried over in a minimal Exif block. The pixels a
/// phone or image_picker writes are in sensor order and rely on that tag to
/// display upright; stripping it would turn portrait photos sideways.
///
/// Returns [src] unchanged if it is not a well-formed JPEG header sequence.
Uint8List stripJpegMetadata(Uint8List src) {
  if (sniffImageFormat(src) != PickedImageFormat.jpeg) return src;
  final kept = <List<int>>[];
  var orientation = 1;
  var i = 2;
  while (true) {
    if (i + 1 >= src.length || src[i] != 0xFF) return src;
    final marker = src[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) {
      kept.add(src.sublist(i)); // scan + everything after it, verbatim
      break;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      kept.add(src.sublist(i, i + 2));
      i += 2;
      continue;
    }
    if (i + 3 >= src.length) return src;
    final end = i + 2 + ((src[i + 2] << 8) | src[i + 3]);
    if (end > src.length) return src;
    final seg = src.sublist(i, end);
    final payload = Uint8List.sublistView(seg, 4);
    if (marker == 0xE1 && _startsWith(payload, _exifId)) {
      orientation = _orientationFromTiff(Uint8List.sublistView(payload, 6));
    } else if (marker == 0xE2 && _startsWith(payload, _iccId)) {
      kept.add(seg);
    } else if (marker == 0xFE || (marker >= 0xE1 && marker <= 0xEF)) {
      // metadata — dropped
    } else {
      kept.add(seg);
    }
    i = end;
  }

  final out = BytesBuilder(copy: false)..add(const [0xFF, 0xD8]);
  var exifWritten = orientation == 1;
  for (final seg in kept) {
    final isApp0 = seg.length > 1 && seg[0] == 0xFF && seg[1] == 0xE0;
    if (!exifWritten && !isApp0) {
      out.add(_minimalExif(orientation));
      exifWritten = true;
    }
    out.add(seg);
  }
  return out.toBytes();
}

/// Orientation (1-8) from a JPEG's Exif, or 1 when it carries none.
int readJpegOrientation(Uint8List src) {
  if (sniffImageFormat(src) != PickedImageFormat.jpeg) return 1;
  var i = 2;
  while (i + 3 < src.length && src[i] == 0xFF) {
    final marker = src[i + 1];
    if (marker == 0xDA || marker == 0xD9) break;
    final end = i + 2 + ((src[i + 2] << 8) | src[i + 3]);
    if (end > src.length) break;
    final payload = Uint8List.sublistView(src, i + 4, end);
    if (marker == 0xE1 && _startsWith(payload, _exifId)) {
      return _orientationFromTiff(Uint8List.sublistView(payload, 6));
    }
    i = end;
  }
  return 1;
}

const List<int> _exifId = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]; // "Exif\0\0"
const List<int> _iccId = [
  0x49, 0x43, 0x43, 0x5F, 0x50, 0x52, 0x4F, 0x46, 0x49, 0x4C, 0x45, 0x00, //
]; // "ICC_PROFILE\0"

bool _startsWith(Uint8List b, List<int> prefix) {
  if (b.length < prefix.length) return false;
  for (var k = 0; k < prefix.length; k++) {
    if (b[k] != prefix[k]) return false;
  }
  return true;
}

/// Reads tag 0x0112 from IFD0 of a TIFF block; 1 on anything unexpected.
int _orientationFromTiff(Uint8List t) {
  if (t.length < 8) return 1;
  final little = t[0] == 0x49 && t[1] == 0x49;
  if (!little && !(t[0] == 0x4D && t[1] == 0x4D)) return 1;
  int u16(int o) => little ? t[o] | (t[o + 1] << 8) : (t[o] << 8) | t[o + 1];
  int u32(int o) => little
      ? t[o] | (t[o + 1] << 8) | (t[o + 2] << 16) | (t[o + 3] << 24)
      : (t[o] << 24) | (t[o + 1] << 16) | (t[o + 2] << 8) | t[o + 3];
  final ifd = u32(4);
  if (ifd + 2 > t.length) return 1;
  final count = u16(ifd);
  for (var k = 0; k < count; k++) {
    final e = ifd + 2 + k * 12;
    if (e + 12 > t.length) return 1;
    if (u16(e) == 0x0112) {
      final v = u16(e + 8);
      return v >= 1 && v <= 8 ? v : 1;
    }
  }
  return 1;
}

/// An APP1 Exif segment holding only the Orientation tag (big-endian TIFF).
List<int> _minimalExif(int orientation) {
  const payloadLen = 6 + 8 + 2 + 12 + 4; // id + header + count + entry + next
  return [
    0xFF, 0xE1, 0x00, payloadLen + 2, //
    ..._exifId,
    0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, // MM, 42, IFD0 @ 8
    0x00, 0x01, // one entry
    0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // Orientation, SHORT, 1
    0x00, orientation, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, // no next IFD
  ];
}
