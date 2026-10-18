import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../../utils/attachment_cipher.dart';

/// Image provider for a LOCAL attachment file (staged pick or cached media).
///
/// Use instead of `FileImage` for any path under the SDK's media store: when
/// `encryptAttachments` is on those files are ciphertext, and this provider
/// reads them through [AttachmentCipher.readPlainBytes], which decrypts in
/// memory. A plain file (option off, or a file staged before it was turned on)
/// is read as is, so behaviour is unchanged for hosts that never enable it.
@immutable
class LocalAttachmentImage extends ImageProvider<LocalAttachmentImage> {
  const LocalAttachmentImage(this.path, {this.scale = 1.0});

  final String path;
  final double scale;

  @override
  Future<LocalAttachmentImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<LocalAttachmentImage>(this);

  @override
  ImageStreamCompleter loadImage(
    LocalAttachmentImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(key, decode),
    scale: key.scale,
    debugLabel: key.path,
    informationCollector: () => <DiagnosticsNode>[
      ErrorDescription('Path: ${key.path}'),
    ],
  );

  Future<ui.Codec> _load(
    LocalAttachmentImage key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await AttachmentCipher.readPlainBytes(key.path);
    if (bytes.lengthInBytes == 0) {
      // Same as FileImage: do not keep a failed load in the cache.
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('$path is empty and cannot be loaded as an image.');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is LocalAttachmentImage &&
      other.path == path &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(path, scale);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'LocalAttachmentImage')}("$path", scale: $scale)';
}
