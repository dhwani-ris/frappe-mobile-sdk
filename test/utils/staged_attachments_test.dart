import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:frappe_mobile_sdk/src/utils/staged_attachments.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('staged_attachments');
    MediaStore.overrideRootForTest(root.path);
  });
  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await root.delete(recursive: true);
  });

  Future<String> stage(String name) async {
    final f = File('${root.path}/$name')..writeAsStringSync(name);
    return MediaStore.stageToOutbox(f);
  }

  test('finds staged paths in the parent and in child rows only', () async {
    final a = await stage('a.jpg');
    final b = await stage('b.jpg');
    final found = await stagedAttachmentPathsIn({
      'photo': a,
      'title': 'Site A', // a plain string is not a path
      'old': '/private/files/x.jpg',
      'marker': 'pending:3',
      'gallery': '/sdcard/DCIM/holiday.jpg', // local, but not ours
      'rows': [
        {'pic': b, 'n': 1},
        'not-a-row',
      ],
    });
    expect(found, {a, b});
  });

  test('replaces values in the parent and in child rows', () async {
    final out = replaceAttachmentValues(
      {
        'photo': '/o/a.jpg',
        'title': 'x',
        'rows': [
          {'pic': '/o/b.jpg'},
        ],
      },
      {'/o/a.jpg': '/private/files/a.jpg', '/o/b.jpg': '/private/files/b.jpg'},
    );
    expect(out['photo'], '/private/files/a.jpg');
    expect(out['title'], 'x');
    expect((out['rows'] as List).single, {'pic': '/private/files/b.jpg'});
  });

  test('uploads only what is not already known', () async {
    final uploaded = <String>[];
    final urls = await uploadStagedAttachments({'/o/a.jpg', '/o/b.jpg'}, (
      path,
    ) async {
      uploaded.add(path);
      return '/private/files/${path.split('/').last}';
    }, known: {'/o/a.jpg': '/private/files/a.jpg'});
    expect(uploaded, ['/o/b.jpg']);
    expect(urls, {
      '/o/a.jpg': '/private/files/a.jpg',
      '/o/b.jpg': '/private/files/b.jpg',
    });
  });

  test(
    'an upload failure names the file instead of sending a raw path',
    () async {
      await expectLater(
        uploadStagedAttachments({
          '/o/outbox/u1/IMG_7.jpg',
        }, (path) async => throw const SocketException('down')),
        throwsA(
          isA<StagedAttachmentUploadException>().having(
            (e) => e.fileName,
            'fileName',
            'IMG_7.jpg',
          ),
        ),
      );
    },
  );

  test(
    'no resolvable store means nothing is staged, not a failed save',
    () async {
      // No root override and no path_provider plugin in a unit test — the same
      // shape as an embedder that cannot locate the documents directory.
      MediaStore.overrideRootForTest(null);
      expect(
        await stagedAttachmentPathsIn({'photo': '/x/outbox/u/a.jpg'}),
        isEmpty,
      );
    },
  );
}
