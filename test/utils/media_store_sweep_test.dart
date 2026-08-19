import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/media_store_usage.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sweep');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
  });

  File src(String name, int bytes) =>
      File('${root.path}/$name')..writeAsBytesSync(List.filled(bytes, 0));

  /// Stages a file then forgets it, simulating the live-set after a process
  /// restart — which is precisely when a file becomes sweepable.
  Future<String> stageFromPreviousSession(String name, int bytes) async {
    final path = await MediaStore.stageToOutbox(
      src(name, bytes),
      nameGen: () => 'u_$name',
    );
    MediaStore.overrideRootForTest(root.path); // clears the live-set
    return path;
  }

  test('sweep deletes a file with no row and no live-set entry', () async {
    final orphan = await stageFromPreviousSession('orphan.jpg', 100);
    expect(await MediaStore.sweepOrphans(const <String>{}), 100);
    expect(File(orphan).existsSync(), isFalse);
  });

  test('sweep SPARES a row-backed file', () async {
    final kept = await stageFromPreviousSession('kept.jpg', 50);
    expect(await MediaStore.sweepOrphans({kept}), 0);
    expect(File(kept).existsSync(), isTrue);
  });

  test('sweep SPARES a live-set file even with no row', () async {
    // The same-session case: a pick sitting in an open form.
    final live = await MediaStore.stageToOutbox(
      src('live.jpg', 40),
      nameGen: () => 'u_live',
    );
    expect(await MediaStore.sweepOrphans(const <String>{}), 0);
    expect(File(live).existsSync(), isTrue);
  });

  test(
    'an abandoned pick SURVIVES its own session, then sweeps after restart',
    () async {
      final abandoned = await MediaStore.stageToOutbox(
        src('abandoned.jpg', 25),
        nameGen: () => 'u_ab',
      );
      expect(await MediaStore.sweepOrphans(const <String>{}), 0);
      expect(
        File(abandoned).existsSync(),
        isTrue,
        reason: 'still live this session',
      );

      MediaStore.overrideRootForTest(root.path); // restart: live-set cleared

      expect(await MediaStore.sweepOrphans(const <String>{}), 25);
      expect(File(abandoned).existsSync(), isFalse);
    },
  );

  test('sweep never touches cache/', () async {
    final staged = await MediaStore.stageToOutbox(
      src('c.jpg', 70),
      nameGen: () => 'u_c',
    );
    await MediaStore.moveToCache(staged, '/files/c.jpg');
    MediaStore.overrideRootForTest(root.path);

    expect(await MediaStore.sweepOrphans(const <String>{}), 0);
    expect(
      File(await MediaStore.cachePathFor('/files/c.jpg')).existsSync(),
      isTrue,
      reason: 'cache is out of scope for this sweep',
    );
  });

  test('sweep is safe on an empty store', () async {
    expect(await MediaStore.sweepOrphans(const <String>{}), 0);
  });

  test('sweep tolerates a file that vanishes after it is listed', () async {
    // A concurrent push can move a staged file into cache/ between the listing
    // and the delete. Absence is not an error and must not be counted as freed.
    final gone = await stageFromPreviousSession('gone.jpg', 80);
    File(gone).deleteSync();
    expect(await MediaStore.sweepOrphans(const <String>{}), 0);
  });

  test('sweep prunes the emptied per-pick directory', () async {
    final orphan = await stageFromPreviousSession('p.jpg', 10);
    await MediaStore.sweepOrphans(const <String>{});
    expect(Directory(File(orphan).parent.path).existsSync(), isFalse);
  });

  test(
    'usage reports four buckets, orphanBytes a SUBSET of outboxBytes',
    () async {
      final orphan = await stageFromPreviousSession('o.jpg', 30);
      final kept = await stageFromPreviousSession('k.jpg', 20);
      final toCache = await MediaStore.stageToOutbox(
        src('cc.jpg', 60),
        nameGen: () => 'u_cc',
      );
      await MediaStore.moveToCache(toCache, '/files/cc.jpg');
      MediaStore.overrideRootForTest(root.path);

      final MediaStoreUsage u = await MediaStore.usage({kept});

      expect(u.outboxBytes, 50, reason: 'orphan + kept');
      expect(u.cacheBytes, 60);
      expect(u.orphanBytes, 30);
      expect(u.orphanCount, 1);
      expect(
        u.totalBytes,
        110,
        reason: 'outbox + cache ONLY — orphanBytes must not be added again',
      );
      expect(File(orphan).existsSync(), isTrue, reason: 'usage never deletes');
    },
  );

  test('usage on an absent store returns zeros', () async {
    final MediaStoreUsage u = await MediaStore.usage(const <String>{});
    expect(u.totalBytes, 0);
    expect(u.orphanCount, 0);
  });
}
