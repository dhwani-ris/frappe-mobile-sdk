// The `media_cache` row must name the file that was actually written.
//
// `MediaStore.cachePathFor` borrows the extension from the SOURCE when the url
// has none — its own docstring names the case ("a `download_file` proxy url that
// carries the name in its query"). `moveToCache` passes `sourcePath`, so it
// writes `<digest><ext>`; the pipeline used to recompute the path WITHOUT
// `sourcePath`, recording `<digest>`. For an extension-less url the two diverge,
// and the divergence is silent in both directions that matter:
//
//   * `MediaResolver` finds the row, `File(localPath).exists()` is false, treats
//     it as a miss and re-downloads — on every view, forever.
//   * The uploaded original at `<digest><ext>` becomes unreachable bytes that no
//     API reclaims: `sweepOrphans` walks `outbox/` only, so nothing short of
//     `clearCache()` will ever remove it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late PendingAttachmentDao dao;
  late Directory storeRoot;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    dao = PendingAttachmentDao(db);
    storeRoot = await Directory.systemTemp.createTemp('cachepathstore');
    MediaStore.overrideRootForTest(storeRoot.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await storeRoot.exists()) await storeRoot.delete(recursive: true);
  });

  /// Enqueues one attachment and resolves it against [fileUrl].
  Future<void> uploadOne(String fileUrl) async {
    final tmp = await Directory.systemTemp.createTemp('attach');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final picked = File('${tmp.path}/photo.jpg')..writeAsStringSync('IMG');
    final staged = await MediaStore.stageToOutbox(picked);

    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: staged,
      fileName: 'photo.jpg',
    );

    final pipeline = AttachmentPipeline(
      dao: dao,
      db: db,
      uploader: (file, {doctype, docname, fileName, isPrivate = true}) async =>
          {'file_url': fileUrl, 'name': 'photo.jpg'},
    );
    await pipeline.resolveForTopParent('P1');
  }

  Future<String?> cachedPathFor(String fileUrl) async {
    final rows = await db.query(
      'media_cache',
      columns: ['local_path'],
      where: 'file_url = ?',
      whereArgs: [fileUrl],
    );
    return rows.isEmpty ? null : rows.first['local_path'] as String?;
  }

  test('an extension-bearing url records a path that exists', () async {
    // Control: this case already agreed, because cachePathFor takes the
    // extension from the url and never consults sourcePath.
    const url = '/private/files/photo.jpg';
    await uploadOne(url);

    final recorded = await cachedPathFor(url);
    expect(recorded, isNotNull);
    expect(File(recorded!).existsSync(), isTrue, reason: recorded);
  });

  test('an extension-LESS url records a path that exists', () async {
    // The regression. The url carries no extension, so `moveToCache` borrows
    // `.jpg` from the staged file and writes `<digest>.jpg`, while the recorded
    // path was computed without the source and named `<digest>`.
    const url = '/api/method/download_file?x=1';
    await uploadOne(url);

    final recorded = await cachedPathFor(url);
    expect(recorded, isNotNull, reason: 'the cache row must be written');
    expect(
      File(recorded!).existsSync(),
      isTrue,
      reason:
          'media_cache names a file that was never written — every view will '
          're-download and the real bytes are unreclaimable: $recorded',
    );
  });

  test('moveToCache reports the destination it actually used', () async {
    // Structural guard: the caller must not have to recompute the path, which
    // is what allowed the two to drift in the first place.
    final tmp = await Directory.systemTemp.createTemp('attach');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    final picked = File('${tmp.path}/scan.png')..writeAsStringSync('PNG');
    final staged = await MediaStore.stageToOutbox(picked);

    const url = '/api/method/download_file?y=2';
    final dest = await MediaStore.moveToCache(staged, url);

    expect(dest, isNotNull, reason: 'a successful move must report its path');
    expect(File(dest!).existsSync(), isTrue, reason: dest);
    expect(dest.endsWith('.png'), isTrue, reason: 'extension from the source');
  });

  test(
    'moveToCache reports null when neither source nor destination exists',
    () async {
      final dest = await MediaStore.moveToCache(
        '${storeRoot.path}/outbox/nope/missing.jpg',
        '/files/missing.jpg',
      );
      expect(dest, isNull);
    },
  );
}
