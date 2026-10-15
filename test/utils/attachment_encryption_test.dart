// Opt-in at-rest encryption of attachments (`FrappeSDK(encryptAttachments:
// true)`). Without it a staged photo sits in clear under outbox/ until it
// uploads, and a lost phone exposes it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/attachment_service.dart';
import 'package:frappe_mobile_sdk/src/api/rest_helper.dart';
import 'package:frappe_mobile_sdk/src/database/daos/media_cache_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/media_resolver.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_error_classifier.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/local_attachment_image.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_cipher.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_pick.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// True when [needle] occurs anywhere in [hay].
bool containsBytes(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// A recognisable plaintext, long enough that a match cannot be chance.
final Uint8List secret = Uint8List.fromList(
  utf8.encode('FICTIONAL-SURVEY-PHOTO-BYTES ' * 40),
);

void main() {
  late Directory storeRoot;
  late Directory tempRoot;
  late Directory outside;
  late AttachmentCipher cipher;

  setUp(() async {
    storeRoot = await Directory.systemTemp.createTemp('enc_store');
    tempRoot = await Directory.systemTemp.createTemp('enc_temp');
    outside = await Directory.systemTemp.createTemp('enc_gallery');
    MediaStore.overrideRootForTest(storeRoot.path);
    MediaStore.overrideTempRootForTest(tempRoot.path);
    cipher = AttachmentCipher(AttachmentCipher.generateKey());
  });

  tearDown(() async {
    AttachmentCipher.resetForTest();
    MediaStore.overrideRootForTest(null);
    MediaStore.overrideTempRootForTest(null);
    for (final d in [storeRoot, tempRoot, outside]) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });

  void enable() => AttachmentCipher.configure(cipher, encryptNewFiles: true);

  Future<File> writeFile(Directory dir, String name, List<int> bytes) async {
    final f = File(p.join(dir.path, name));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  group('AttachmentCipher format', () {
    test('round trip: encrypt then decrypt returns the plaintext', () async {
      final sealed = await cipher.encrypt(secret);
      expect(AttachmentCipher.hasMagic(sealed), isTrue);
      expect(
        sealed.length,
        kEncryptedAttachmentMagic.length + 12 + secret.length + 16,
        reason: 'magic + 12-byte nonce + ciphertext + 16-byte MAC',
      );
      expect(containsBytes(sealed, secret.sublist(0, 32)), isFalse);
      expect(await cipher.decrypt(sealed), secret);
    });

    test('two encryptions of the same bytes differ (fresh nonce)', () async {
      final a = await cipher.encrypt(secret);
      final b = await cipher.encrypt(secret);
      expect(a, isNot(equals(b)));
    });

    test('a tampered file fails to decrypt', () async {
      final sealed = await cipher.encrypt(secret);
      final tampered = Uint8List.fromList(sealed);
      tampered[kEncryptedAttachmentMagic.length + 12 + 5] ^= 0x01;
      await expectLater(
        cipher.decrypt(tampered),
        throwsA(isA<AttachmentDecryptionException>()),
      );

      enable();
      final f = await writeFile(storeRoot, 'tampered.jpg', tampered);
      await expectLater(
        AttachmentCipher.readPlainBytes(f.path),
        throwsA(isA<AttachmentDecryptionException>()),
      );
    });

    test('a truncated file fails to decrypt', () async {
      final sealed = await cipher.encrypt(secret);
      await expectLater(
        cipher.decrypt(sealed.sublist(0, kEncryptedAttachmentMagic.length + 8)),
        throwsA(isA<AttachmentDecryptionException>()),
      );
    });

    test('the wrong key fails to decrypt', () async {
      final sealed = await cipher.encrypt(secret);
      final other = AttachmentCipher(AttachmentCipher.generateKey());
      await expectLater(
        other.decrypt(sealed),
        throwsA(isA<AttachmentDecryptionException>()),
      );
    });

    test(
      'an encrypted file with no key loaded is an error, not plain',
      () async {
        final f = await writeFile(
          storeRoot,
          'x.jpg',
          await cipher.encrypt(secret),
        );
        AttachmentCipher.resetForTest();
        await expectLater(
          AttachmentCipher.readPlainBytes(f.path),
          throwsA(isA<AttachmentDecryptionException>()),
        );
      },
    );

    test('a plain legacy file passes through unchanged', () async {
      enable();
      final f = await writeFile(storeRoot, 'legacy.jpg', secret);
      expect(await AttachmentCipher.isEncryptedFile(f.path), isFalse);
      expect(await AttachmentCipher.readPlainBytes(f.path), secret);
    });

    test('isEncryptedFile is false for a missing file, never throws', () async {
      expect(
        await AttachmentCipher.isEncryptedFile(p.join(storeRoot.path, 'nope')),
        isFalse,
      );
    });

    test('a decryption failure is a terminal attachment error', () {
      expect(
        isTerminalAttachmentError(const AttachmentDecryptionException('x')),
        isTrue,
      );
    });
  });

  test('FrappeSDK.encryptAttachments is off unless asked for', () {
    expect(FrappeSDK(baseUrl: 'https://x.example').encryptAttachments, isFalse);
    expect(
      FrappeSDK(
        baseUrl: 'https://x.example',
        encryptAttachments: true,
      ).encryptAttachments,
      isTrue,
    );
  });

  group('key storage', () {
    test(
      'loadOrCreate creates one 32-byte key, then reuses it; namespaced',
      () async {
        FlutterSecureStorage.setMockInitialValues(<String, String>{});
        const storage = FlutterSecureStorage();
        expect(
          await AttachmentCipher.loadExisting(storage, databaseAppName: 'a'),
          isNull,
          reason: 'loadExisting never creates a key',
        );
        final first = await AttachmentCipher.loadOrCreate(
          storage,
          databaseAppName: 'a',
        );
        final again = await AttachmentCipher.loadOrCreate(
          storage,
          databaseAppName: 'a',
        );
        final stored = await storage.read(key: attachmentKeyStorageName('a'));
        expect(base64Decode(stored!).length, 32);
        // Same key: what one instance wrote the other reads.
        expect(await again.decrypt(await first.encrypt(secret)), secret);

        final otherApp = await AttachmentCipher.loadOrCreate(
          storage,
          databaseAppName: 'b',
        );
        await expectLater(
          otherApp.decrypt(await first.encrypt(secret)),
          throwsA(isA<AttachmentDecryptionException>()),
        );
      },
    );
  });

  group('staging', () {
    test(
      'with the option off, staging is the plain copy it always was',
      () async {
        final src = await writeFile(tempRoot, 'pick.jpg', secret);
        final staged = await MediaStore.stageToOutbox(src);
        expect(File(staged).readAsBytesSync(), secret);
        expect(
          src.existsSync(),
          isTrue,
          reason: 'option off: source untouched',
        );
      },
    );

    test('with the option on, no plain bytes reach the outbox', () async {
      enable();
      final src = await writeFile(outside, 'Site Photo.jpg', secret);
      final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'uid1');

      expect(staged.endsWith('/outbox/uid1/Site Photo.jpg'), isTrue);
      final onDisk = File(staged).readAsBytesSync();
      expect(
        onDisk.sublist(0, kEncryptedAttachmentMagic.length),
        utf8.encode(kEncryptedAttachmentMagic),
      );
      expect(containsBytes(onDisk, secret.sublist(0, 32)), isFalse);

      // Nothing else under the store holds the plaintext either (no temp
      // file left behind, no plain sibling).
      final all = storeRoot
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(all.map((f) => f.path), [staged]);

      expect(await AttachmentCipher.readPlainBytes(staged), secret);
    });

    test(
      'a picker scratch copy in the app temp dir is deleted after staging',
      () async {
        enable();
        final src = await writeFile(tempRoot, 'image_picker_123.jpg', secret);
        await MediaStore.stageToOutbox(src);
        expect(src.existsSync(), isFalse);
      },
    );

    test('a file outside the app temp dir is never deleted', () async {
      enable();
      final src = await writeFile(outside, 'DCIM/holiday.jpg', secret);
      await MediaStore.stageToOutbox(src);
      expect(src.existsSync(), isTrue);
    });
  });

  group('upload', () {
    Future<List<int>> captureUpload(
      Future<void> Function(AttachmentService svc) run,
    ) async {
      late List<int> body;
      final client = MockClient.streaming((req, stream) async {
        body = await stream.toBytes();
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'message': {'file_url': '/private/files/x.jpg', 'name': 'F-1'},
              }),
            ),
          ),
          200,
        );
      });
      await run(AttachmentService(RestHelper('http://x', client: client)));
      return body;
    }

    test(
      'an encrypted staged file is uploaded as decrypted bytes, keeping its name',
      () async {
        enable();
        final src = await writeFile(outside, 'Site Photo.jpg', secret);
        final staged = await MediaStore.stageToOutbox(src);

        Map<String, dynamic>? resp;
        final body = await captureUpload((svc) async {
          resp = await svc.uploadFile(File(staged), fileName: 'Site Photo.jpg');
        });

        expect(resp!['file_url'], '/private/files/x.jpg');
        expect(containsBytes(body, secret), isTrue);
        expect(
          containsBytes(body, utf8.encode(kEncryptedAttachmentMagic)),
          isFalse,
          reason: 'ciphertext must never be sent to the server',
        );
        final text = utf8.decode(body, allowMalformed: true);
        expect(text, contains('filename="Site Photo.jpg"'));
        expect(text, contains('name="is_private"'));
        // The staged file is still ciphertext: no plain temp copy was made.
        expect(
          AttachmentCipher.hasMagic(File(staged).readAsBytesSync()),
          isTrue,
        );
      },
    );

    test('a plain legacy staged file still uploads as before', () async {
      final f = await writeFile(storeRoot, 'outbox/u/legacy.jpg', secret);
      final body = await captureUpload((svc) async {
        await svc.uploadFile(f, fileName: 'legacy.jpg');
      });
      expect(containsBytes(body, secret), isTrue);
    });

    test(
      'pick -> stage -> inline upload sends plaintext, stores nothing plain',
      () async {
        enable();
        final picked = await writeFile(tempRoot, 'scaled_1.jpg', secret);
        late List<int> body;
        final client = MockClient.streaming((req, stream) async {
          body = await stream.toBytes();
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                jsonEncode({
                  'message': {
                    'file_url': '/private/files/s.jpg',
                    'name': 'F-2',
                  },
                }),
              ),
            ),
            200,
          );
        });
        final svc = AttachmentService(RestHelper('http://x', client: client));
        final stored = await resolvePickedAttachment(
          picked: picked,
          online: true,
          uploadFile: (f) async =>
              (await svc.uploadFile(
                    f,
                    fileName: p.basename(f.path),
                  ))['file_url']
                  as String?,
        );
        expect(stored, '/private/files/s.jpg');
        expect(containsBytes(body, secret), isTrue);
        expect(picked.existsSync(), isFalse, reason: 'scratch copy removed');
      },
    );
  });

  group('cache and viewing', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    test(
      'a downloaded file is cached encrypted when the option is on',
      () async {
        enable();
        final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
        addTearDown(db.close);
        for (final s in systemTablesDDL()) {
          await db.execute(s);
        }
        final resolver = MediaResolver(
          cache: MediaCacheDao(db),
          isOnline: () => true,
          fetch: (_) async => secret,
        );
        final path = await resolver.resolve('/private/files/remote.jpg');
        expect(path, isNotNull);
        final onDisk = File(path!).readAsBytesSync();
        expect(AttachmentCipher.hasMagic(onDisk), isTrue);
        expect(containsBytes(onDisk, secret.sublist(0, 32)), isFalse);
        expect(await AttachmentCipher.readPlainBytes(path), secret);
        expect(File(AttachmentCipher.tempPathFor(path)).existsSync(), isFalse);
      },
    );

    test('a staged file moved to cache after upload stays encrypted', () async {
      enable();
      final src = await writeFile(outside, 'a.jpg', secret);
      final staged = await MediaStore.stageToOutbox(src);
      final cached = await MediaStore.moveToCache(staged, '/files/a.jpg');
      expect(
        AttachmentCipher.hasMagic(File(cached!).readAsBytesSync()),
        isTrue,
      );
      expect(await AttachmentCipher.readPlainBytes(cached), secret);
    });

    test(
      'plainPathForViewer decrypts into the viewer scratch dir; plain passes',
      () async {
        enable();
        final src = await writeFile(outside, 'report.pdf', secret);
        final staged = await MediaStore.stageToOutbox(src);
        final viewPath = await MediaStore.plainPathForViewer(staged);
        expect(p.isWithin(await MediaStore.viewerTempDir(), viewPath), isTrue);
        expect(p.basename(viewPath), 'report.pdf');
        expect(File(viewPath).readAsBytesSync(), secret);

        final plain = await writeFile(storeRoot, 'plain.pdf', secret);
        expect(await MediaStore.plainPathForViewer(plain.path), plain.path);

        await MediaStore.clearViewerTempCache();
        expect(File(viewPath).existsSync(), isFalse);
      },
    );

    testWidgets('LocalAttachmentImage decodes an encrypted image', (
      tester,
    ) async {
      enable();
      // 1x1 transparent PNG.
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
      );
      final path = await tester.runAsync(() async {
        final f = File(p.join(storeRoot.path, 'pixel.png'));
        await AttachmentCipher.writeEncrypted(f.path, png);
        return f.path;
      });
      final info = await tester.runAsync(() async {
        final stream = LocalAttachmentImage(
          path!,
        ).resolve(ImageConfiguration.empty);
        final completer = Completer<ImageInfo>();
        stream.addListener(
          ImageStreamListener(
            (i, _) => completer.complete(i),
            onError: (e, st) => completer.completeError(e, st),
          ),
        );
        return completer.future;
      });
      expect(info!.image.width, 1);
      expect(info.image.height, 1);
    });
  });
}
