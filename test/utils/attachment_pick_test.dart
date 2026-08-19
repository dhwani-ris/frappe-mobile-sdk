import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/utils/attachment_pick.dart';

void main() {
  // Fakes injected in place of the real copy/delete helpers.
  late List<String> deleted;
  Future<String> fakeCopy(File src) async =>
      '/appdocs/mform_attachments/dur.jpg';
  Future<void> fakeDelete(String path) async => deleted.add(path);

  setUp(() => deleted = []);

  final picked = File('/cache/IMG_1.jpg');

  test('offline: stores the durable copy, never uploads', () async {
    var uploadCalled = false;
    final result = await resolvePickedAttachment(
      picked: picked,
      online: false,
      uploadFile: (f) async {
        uploadCalled = true;
        return 'https://server/files/x.jpg';
      },
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
    expect(uploadCalled, isFalse);
    expect(deleted, isEmpty);
  });

  test(
    'online: uploads from the durable copy, returns url, deletes copy',
    () async {
      final result = await resolvePickedAttachment(
        picked: picked,
        online: true,
        uploadFile: (f) async => '/files/uploaded.jpg',
        copyToStore: fakeCopy,
        deleteCopy: fakeDelete,
      );
      expect(result, '/files/uploaded.jpg');
      expect(deleted, ['/appdocs/mform_attachments/dur.jpg']); // copy reclaimed
    },
  );

  test('online but upload throws: falls back to durable copy', () async {
    final result = await resolvePickedAttachment(
      picked: picked,
      online: true,
      uploadFile: (f) async =>
          throw const SocketException('offline mid-upload'),
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
    expect(deleted, isEmpty); // keep the copy for save-time enqueue
  });

  test('online but upload returns empty: falls back to durable copy', () async {
    final result = await resolvePickedAttachment(
      picked: picked,
      online: true,
      uploadFile: (f) async => '',
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
  });

  test('no uploader (uploadFile null): stores durable copy', () async {
    final result = await resolvePickedAttachment(
      picked: picked,
      online: true,
      uploadFile: null,
      copyToStore: fakeCopy,
      deleteCopy: fakeDelete,
    );
    expect(result, '/appdocs/mform_attachments/dur.jpg');
  });

  group('pick-time size guard', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sizeguard');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    File realFile(String name, int bytes) =>
        File('${tmp.path}/$name')..writeAsBytesSync(List.filled(bytes, 0));

    test('a file over the limit is refused BEFORE staging', () async {
      var copied = false;
      await expectLater(
        resolvePickedAttachment(
          picked: realFile('big.bin', 2048),
          online: false,
          maxBytes: 1024,
          copyToStore: (f) async {
            copied = true;
            return '/never';
          },
          deleteCopy: fakeDelete,
        ),
        throwsA(isA<AttachmentTooLargeException>()),
      );
      expect(
        copied,
        isFalse,
        reason: 'nothing may be staged for a refused pick',
      );
    });

    test('a file exactly at the limit is accepted', () async {
      final out = await resolvePickedAttachment(
        picked: realFile('ok.bin', 1024),
        online: false,
        maxBytes: 1024,
        copyToStore: fakeCopy,
        deleteCopy: fakeDelete,
      );
      expect(out, isNotNull);
    });

    test(
      'the exception carries both sizes so the message can be specific',
      () async {
        try {
          await resolvePickedAttachment(
            picked: realFile('big.bin', 5000),
            online: false,
            maxBytes: 1000,
            copyToStore: fakeCopy,
            deleteCopy: fakeDelete,
          );
          fail('expected AttachmentTooLargeException');
        } on AttachmentTooLargeException catch (e) {
          expect(e.sizeBytes, 5000);
          expect(e.limitBytes, 1000);
        }
      },
    );

    test(
      'an unstattable file skips the guard rather than refusing the pick',
      () async {
        // Refusing because we could not measure would block a legitimate pick.
        final out = await resolvePickedAttachment(
          picked: File('${tmp.path}/does-not-exist.bin'),
          online: false,
          maxBytes: 1,
          copyToStore: fakeCopy,
          deleteCopy: fakeDelete,
        );
        expect(out, '/appdocs/mform_attachments/dur.jpg');
      },
    );
  });

  group('online upload failure is classified', () {
    test(
      'TRANSIENT: falls back to the staged copy for later queueing',
      () async {
        final out = await resolvePickedAttachment(
          picked: picked,
          online: true,
          uploadFile: (f) async => throw NetworkException('socket closed'),
          copyToStore: fakeCopy,
          deleteCopy: fakeDelete,
        );
        expect(out, '/appdocs/mform_attachments/dur.jpg');
        expect(
          deleted,
          isEmpty,
          reason: 'the file is still needed for the queue',
        );
      },
    );

    test('TERMINAL: rethrows and discards the staged copy', () async {
      // Queueing a file the server has already refused would only guarantee a
      // blocked push later, so surface it now while the user can re-take it.
      await expectLater(
        resolvePickedAttachment(
          picked: picked,
          online: true,
          uploadFile: (f) async => throw ValidationException(
            'File size exceeded',
            {'exc_type': 'MaxFileSizeReachedError'},
          ),
          copyToStore: fakeCopy,
          deleteCopy: fakeDelete,
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(deleted, ['/appdocs/mform_attachments/dur.jpg']);
    });
  });

  group('offline mode defers the upload even when connected', () {
    test('offline mode ON + device ONLINE: stages, does NOT upload', () async {
      var uploads = 0;
      final out = await resolvePickedAttachment(
        picked: picked,
        online: true,
        offlineModeEnabled: true,
        uploadFile: (f) async {
          uploads++;
          return 'https://server/files/x.jpg';
        },
        copyToStore: fakeCopy,
        deleteCopy: fakeDelete,
      );
      expect(
        uploads,
        0,
        reason: 'offline-first means data entry never blocks on the network',
      );
      expect(out, '/appdocs/mform_attachments/dur.jpg');
      expect(deleted, isEmpty, reason: 'the staged file is what gets queued');
    });

    test(
      'offline mode OFF + device ONLINE: uploads inline (unchanged)',
      () async {
        var uploads = 0;
        final out = await resolvePickedAttachment(
          picked: picked,
          online: true,
          offlineModeEnabled: false,
          uploadFile: (f) async {
            uploads++;
            return 'https://server/files/x.jpg';
          },
          copyToStore: fakeCopy,
          deleteCopy: fakeDelete,
        );
        expect(uploads, 1);
        expect(out, 'https://server/files/x.jpg');
      },
    );

    test('offline mode ON + device OFFLINE: stages (unchanged)', () async {
      var uploads = 0;
      final out = await resolvePickedAttachment(
        picked: picked,
        online: false,
        offlineModeEnabled: true,
        uploadFile: (f) async {
          uploads++;
          return 'x';
        },
        copyToStore: fakeCopy,
        deleteCopy: fakeDelete,
      );
      expect(uploads, 0);
      expect(out, '/appdocs/mform_attachments/dur.jpg');
    });

    test('the default is OFF, so existing hosts keep inline upload', () async {
      var uploads = 0;
      await resolvePickedAttachment(
        picked: picked,
        online: true,
        uploadFile: (f) async {
          uploads++;
          return 'https://server/files/x.jpg';
        },
        copyToStore: fakeCopy,
        deleteCopy: fakeDelete,
      );
      expect(uploads, 1);
    });

    test('the size guard still runs first in offline mode', () async {
      final tmp = await Directory.systemTemp.createTemp('offguard');
      addTearDown(() async => tmp.delete(recursive: true));
      final big = File('${tmp.path}/big.bin')
        ..writeAsBytesSync(List.filled(2048, 0));
      var copied = false;
      await expectLater(
        resolvePickedAttachment(
          picked: big,
          online: true,
          offlineModeEnabled: true,
          maxBytes: 1024,
          copyToStore: (f) async {
            copied = true;
            return '/never';
          },
          deleteCopy: fakeDelete,
        ),
        throwsA(isA<AttachmentTooLargeException>()),
      );
      expect(copied, isFalse);
    });
  });
}
