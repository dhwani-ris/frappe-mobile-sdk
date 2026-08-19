import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';

/// Total bytes across both store directories. `MediaStore.usage` is the single
/// size API; the referenced-set argument only affects orphan accounting, which
/// `totalBytes` does not include.
Future<int> storeSize() async =>
    (await MediaStore.usage(const <String>{})).totalBytes;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mediastore');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  File srcFile(String name, String content) {
    final f = File('${root.path}/$name')..createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  test(
    'stageToOutbox keeps the ORIGINAL filename under a unique directory',
    () async {
      // The user's filename is the only place it survives: it cannot ride through
      // onChanged, and a uuid-named file loses it permanently. A per-pick
      // directory gives collision safety without renaming the file.
      final src = srcFile('Site Photo.jpg', 'A');
      final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'uid1');
      expect(
        staged.endsWith('/outbox/uid1/Site Photo.jpg'),
        isTrue,
        reason: staged,
      );
      expect(File(staged).readAsStringSync(), 'A');
      expect(src.existsSync(), isTrue, reason: 'staging copies, never moves');
    },
  );

  test('two picks of the same filename do not collide', () async {
    final a = await MediaStore.stageToOutbox(
      srcFile('report.pdf', 'A'),
      nameGen: () => 'uid1',
    );
    final b = await MediaStore.stageToOutbox(
      srcFile('report.pdf', 'B'),
      nameGen: () => 'uid2',
    );
    expect(a, isNot(b));
    expect(File(a).readAsStringSync(), 'A');
    expect(File(b).readAsStringSync(), 'B');
  });

  test('stageToOutbox handles a source with no extension', () async {
    final src = srcFile('noext', 'B');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'uid1');
    expect(staged.endsWith('/outbox/uid1/noext'), isTrue, reason: staged);
  });

  test('cachePathFor is deterministic and keeps the extension', () async {
    final a = await MediaStore.cachePathFor('/files/a.jpg');
    final b = await MediaStore.cachePathFor('/files/a.jpg');
    expect(a, b, reason: 'same url must always map to the same path');
    expect(a.endsWith('.jpg'), isTrue, reason: a);
    expect(a.contains('/cache/'), isTrue, reason: a);

    final c = await MediaStore.cachePathFor('/files/b.jpg');
    expect(c, isNot(a), reason: 'different urls must not collide');
  });

  test('cachePathFor borrows the extension from the source when the url '
      'has none', () async {
    final p = await MediaStore.cachePathFor(
      '/api/method/download_file?x=1',
      sourcePath: '/outbox/abc.png',
    );
    expect(p.endsWith('.png'), isTrue, reason: p);
  });

  test('moveToCache relocates the file and removes the staged copy', () async {
    final src = srcFile('IMG_2.jpg', 'C');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm1');
    final ok = await MediaStore.moveToCache(staged, '/files/x.jpg') != null;
    expect(ok, isTrue);
    expect(File(staged).existsSync(), isFalse);
    final cached = await MediaStore.cachePathFor('/files/x.jpg');
    expect(File(cached).readAsStringSync(), 'C');
  });

  test(
    'moveToCache is idempotent when the destination already exists',
    () async {
      final src = srcFile('IMG_3.jpg', 'D');
      final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm2');
      expect(await MediaStore.moveToCache(staged, '/files/y.jpg'), isNotNull);
      // Second call: the staged file is gone and the destination is present.
      // Must report success so an interrupted upload can resume.
      expect(await MediaStore.moveToCache(staged, '/files/y.jpg'), isNotNull);
      final cached = await MediaStore.cachePathFor('/files/y.jpg');
      expect(File(cached).readAsStringSync(), 'D');
    },
  );

  test(
    'moveToCache returns null when neither source nor destination exists',
    () async {
      final ok = await MediaStore.moveToCache(
        '${root.path}/outbox/never.jpg',
        '/files/z.jpg',
      );
      expect(
        ok,
        isNull,
        reason: 'cache population must not silently claim success',
      );
    },
  );

  test('storeSize counts both directories', () async {
    final src = srcFile('IMG_4.jpg', '12345');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm3');
    expect(await storeSize(), 5);
    await MediaStore.moveToCache(staged, '/files/v.jpg');
    expect(
      await storeSize(),
      5,
      reason: 'moving between dirs must not change the total',
    );
  });

  test('storeSize is 0 when nothing has been stored', () async {
    expect(await storeSize(), 0);
  });

  test('clearAll removes both directories', () async {
    final src = srcFile('IMG_5.jpg', 'E');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm4');
    await MediaStore.moveToCache(staged, '/files/w.jpg');
    final other = srcFile('IMG_6.jpg', 'F');
    await MediaStore.stageToOutbox(other, nameGen: () => 'm5');

    await MediaStore.clearAll();

    expect(await storeSize(), 0);
    expect(
      File(await MediaStore.cachePathFor('/files/w.jpg')).existsSync(),
      isFalse,
    );
  });

  test('deleteOutboxCopy removes the file and is safe when absent', () async {
    final src = srcFile('IMG_7.jpg', 'G');
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'm6');
    await MediaStore.deleteOutboxCopy(staged);
    expect(File(staged).existsSync(), isFalse);
    // Second call must not throw.
    await MediaStore.deleteOutboxCopy(staged);
  });

  group('isStagedPath', () {
    test('accepts a real staged file', () async {
      final staged = await MediaStore.stageToOutbox(
        srcFile('a.jpg', 'A'),
        nameGen: () => 'uid1',
      );
      expect(await MediaStore.isStagedPath(staged), isTrue);
    });

    test('rejects a host path outside the store', () async {
      // A host may legitimately set a field to a gallery path. Deleting that
      // on replace would destroy the user's own photo.
      expect(
        await MediaStore.isStagedPath('/sdcard/DCIM/holiday.jpg'),
        isFalse,
      );
    });

    test('rejects a ../ escape', () async {
      expect(
        await MediaStore.isStagedPath(
          '${root.path}/mform_attachments/outbox/../../etc/passwd',
        ),
        isFalse,
        reason: 'a prefix match would have admitted this',
      );
    });

    test('rejects a similarly named sibling directory', () async {
      expect(
        await MediaStore.isStagedPath(
          '${root.path}/mform_attachments/outbox_old/a.jpg',
        ),
        isFalse,
        reason: 'a prefix match would have admitted this too',
      );
    });

    test('rejects a cache path', () async {
      final c = await MediaStore.cachePathFor('/files/a.jpg');
      expect(await MediaStore.isStagedPath(c), isFalse);
    });

    test('rejects the outbox root itself and empty input', () async {
      expect(
        await MediaStore.isStagedPath('${root.path}/mform_attachments/outbox'),
        isFalse,
      );
      expect(await MediaStore.isStagedPath(''), isFalse);
    });
  });

  group('session live-set', () {
    test('staging registers the path', () async {
      final staged = await MediaStore.stageToOutbox(
        srcFile('a.jpg', 'A'),
        nameGen: () => 'uid1',
      );
      expect(MediaStore.stagedThisSession, contains(staged));
    });

    test('entries are NOT removed when the file moves to cache', () async {
      // Once saved, the pending_attachments row protects the file anyway, so
      // double protection is free and avoids coupling MediaStore to LocalWriter.
      final staged = await MediaStore.stageToOutbox(
        srcFile('b.jpg', 'B'),
        nameGen: () => 'uid2',
      );
      await MediaStore.moveToCache(staged, '/files/b.jpg');
      expect(MediaStore.stagedThisSession, contains(staged));
    });

    test('clearAll empties the live-set', () async {
      await MediaStore.stageToOutbox(
        srcFile('c.jpg', 'C'),
        nameGen: () => 'u3',
      );
      await MediaStore.clearAll();
      expect(MediaStore.stagedThisSession, isEmpty);
    });

    test('overrideRootForTest resets it, so tests do not leak', () async {
      await MediaStore.stageToOutbox(
        srcFile('d.jpg', 'D'),
        nameGen: () => 'u4',
      );
      expect(MediaStore.stagedThisSession, isNotEmpty);
      MediaStore.overrideRootForTest(root.path);
      expect(MediaStore.stagedThisSession, isEmpty);
    });

    test('the view is unmodifiable', () async {
      expect(
        () => MediaStore.stagedThisSession.add('/x'),
        throwsUnsupportedError,
      );
    });
  });
}
