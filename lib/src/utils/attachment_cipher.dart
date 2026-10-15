import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// First bytes of every attachment file this SDK encrypted.
///
/// A file that does not start with these bytes is read as plain. That is what
/// keeps files staged or cached before `encryptAttachments` was switched on
/// working: they carry no header, so they pass through untouched.
const String kEncryptedAttachmentMagic = 'FMSDK-ENC1\n';

final Uint8List _magic = Uint8List.fromList(
  ascii.encode(kEncryptedAttachmentMagic),
);

const int _nonceLength = 12;
const int _macLength = 16;
const int _keyLength = 32;

/// Secure-storage key under which the attachment key is kept. Namespaced by
/// `databaseAppName` so two SDK-backed apps (or two databases in one app) never
/// share a key.
String attachmentKeyStorageName(String? databaseAppName) {
  final ns = databaseAppName?.trim();
  return (ns == null || ns.isEmpty)
      ? 'frappe_sdk_attachment_key'
      : 'frappe_sdk_attachment_key__$ns';
}

/// Thrown when an encrypted attachment cannot be decrypted: the file was
/// altered or truncated, or the key that wrote it is gone.
class AttachmentDecryptionException implements Exception {
  final String message;
  const AttachmentDecryptionException(this.message);

  @override
  String toString() => 'AttachmentDecryptionException: $message';
}

/// AES-256-GCM encryption of attachment bytes at rest.
///
/// File format: `FMSDK-ENC1\n` + 12-byte nonce + ciphertext + 16-byte MAC.
/// The whole file is held in memory while it is encrypted or decrypted, which
/// is fine for the 10 MB pick limit and 25 MB download cap this SDK enforces.
///
/// The SDK holds one process-wide instance, set by `FrappeSDK.initialize`
/// through [configure]. Every reader of a staged or cached file goes through
/// [readPlainBytes], so readers do not need to know whether the option is on.
class AttachmentCipher {
  AttachmentCipher(List<int> key)
    : assert(key.length == _keyLength, 'key must be 32 bytes'),
      _key = SecretKey(List<int>.unmodifiable(key));

  static final AesGcm _algorithm = AesGcm.with256bits();
  final SecretKey _key;

  static AttachmentCipher? _active;
  static bool _encryptNew = false;

  /// The cipher used to read encrypted files, or null when no key is loaded.
  static AttachmentCipher? get active => _active;

  /// True when files written from now on must be encrypted.
  static bool get encryptsNewFiles => _encryptNew && _active != null;

  /// Sets the process-wide cipher.
  ///
  /// [encryptNewFiles] false with a non-null [cipher] is the "option switched
  /// off after being on" case: new files are written plain, but files that
  /// were encrypted earlier can still be read.
  static void configure(
    AttachmentCipher? cipher, {
    required bool encryptNewFiles,
  }) {
    _active = cipher;
    _encryptNew = encryptNewFiles;
  }

  /// Clears the process-wide cipher.
  @visibleForTesting
  static void resetForTest() => configure(null, encryptNewFiles: false);

  /// 32 random bytes from a cryptographically secure source.
  static Uint8List generateKey() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(_keyLength, (_) => rnd.nextInt(256)),
    );
  }

  /// Reads the key from [storage], creating and storing one if absent.
  static Future<AttachmentCipher> loadOrCreate(
    FlutterSecureStorage storage, {
    String? databaseAppName,
  }) async {
    final name = attachmentKeyStorageName(databaseAppName);
    final existing = await _readKey(storage, name);
    if (existing != null) return AttachmentCipher(existing);
    final key = generateKey();
    await storage.write(key: name, value: base64Encode(key));
    return AttachmentCipher(key);
  }

  /// Reads the key from [storage] without creating one. Null when absent.
  static Future<AttachmentCipher?> loadExisting(
    FlutterSecureStorage storage, {
    String? databaseAppName,
  }) async {
    final key = await _readKey(
      storage,
      attachmentKeyStorageName(databaseAppName),
    );
    return key == null ? null : AttachmentCipher(key);
  }

  static Future<Uint8List?> _readKey(
    FlutterSecureStorage storage,
    String name,
  ) async {
    final raw = await storage.read(key: name);
    if (raw == null || raw.isEmpty) return null;
    final bytes = base64Decode(raw);
    if (bytes.length != _keyLength) {
      // Never silently replace a key: files encrypted with it would become
      // unreadable without anyone being told.
      throw StateError(
        'Stored attachment key "$name" is ${bytes.length} bytes, expected '
        '$_keyLength',
      );
    }
    return bytes;
  }

  /// True when [bytes] starts with [kEncryptedAttachmentMagic].
  static bool hasMagic(List<int> bytes) {
    if (bytes.length < _magic.length) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  /// True when the file at [path] starts with the magic header.
  ///
  /// Never throws: a missing or unreadable file reads as "not encrypted", so a
  /// caller falls through to its existing plain-file behaviour (and its
  /// existing error for a missing file).
  static Future<bool> isEncryptedFile(String path) async {
    RandomAccessFile? raf;
    try {
      raf = await File(path).open();
      final head = await raf.read(_magic.length);
      return hasMagic(head);
    } catch (_) {
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// Encrypts [plain] into the on-disk format.
  Future<Uint8List> encrypt(List<int> plain) async {
    final nonce = _algorithm.newNonce();
    final box = await _algorithm.encrypt(plain, secretKey: _key, nonce: nonce);
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.takeBytes();
  }

  /// Decrypts bytes in the on-disk format.
  ///
  /// Throws [AttachmentDecryptionException] when the header is missing, the
  /// data is truncated, or the MAC does not verify (tampered file, wrong key).
  Future<Uint8List> decrypt(List<int> data) async {
    if (!hasMagic(data)) {
      throw const AttachmentDecryptionException('missing header');
    }
    final start = _magic.length;
    if (data.length < start + _nonceLength + _macLength) {
      throw const AttachmentDecryptionException('file is truncated');
    }
    final nonce = data.sublist(start, start + _nonceLength);
    final cipherText = data.sublist(
      start + _nonceLength,
      data.length - _macLength,
    );
    final mac = Mac(data.sublist(data.length - _macLength));
    try {
      final plain = await _algorithm.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: _key,
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const AttachmentDecryptionException(
        'authentication failed (file altered or wrong key)',
      );
    }
  }

  /// The plain bytes of the local attachment at [path].
  ///
  /// Files with the magic header are decrypted with [active]; any other file
  /// is returned as is (legacy plain files, and every file when the option was
  /// never used). Throws [AttachmentDecryptionException] when an encrypted
  /// file cannot be decrypted, including when no key is loaded.
  static Future<Uint8List> readPlainBytes(String path) async {
    final data = await File(path).readAsBytes();
    if (!hasMagic(data)) return data;
    final cipher = _active;
    if (cipher == null) {
      throw const AttachmentDecryptionException(
        'file is encrypted but no attachment key is loaded',
      );
    }
    return cipher.decrypt(data);
  }

  /// Encrypts [plain] with [active] and writes it to [dest] through a temp file
  /// in the same directory plus a rename.
  ///
  /// Only ciphertext ever touches the disk, so a crash leaves at worst a
  /// partial `.part` file of ciphertext, never a plain copy. Throws
  /// [StateError] when no cipher is loaded.
  static Future<void> writeEncrypted(String dest, List<int> plain) async {
    final cipher = _active;
    if (cipher == null) {
      throw StateError('writeEncrypted called with no attachment key loaded');
    }
    final sealed = await cipher.encrypt(plain);
    final tmp = File(tempPathFor(dest));
    try {
      await tmp.writeAsBytes(sealed, flush: true);
      await tmp.rename(dest);
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// The temp path [writeEncrypted] uses for [dest].
  static String tempPathFor(String dest) => '$dest.part';
}
