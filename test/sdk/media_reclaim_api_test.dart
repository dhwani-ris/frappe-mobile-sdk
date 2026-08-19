import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Composes what `FrappeSDK.mediaStoreUsage()` / `sweepOrphanedMedia()` do,
/// because constructing a real SDK needs a full `initialize()` with a live
/// client. What this pins is the CONTRACT those methods must implement — above
/// all that a FAILED referenced-set query results in zero deletions.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late Directory root;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    root = await Directory.systemTemp.createTemp('reclaimapi');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a queued attachment is never swept, an abandoned one is', () async {
    final queuedSrc = File('${root.path}/q.jpg')..writeAsBytesSync([1, 2, 3]);
    final queued = await MediaStore.stageToOutbox(
      queuedSrc,
      nameGen: () => 'uq',
    );
    await PendingAttachmentDao(db).enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: queued,
    );
    final abandonedSrc = File('${root.path}/a.jpg')..writeAsBytesSync([9, 9]);
    final abandoned = await MediaStore.stageToOutbox(
      abandonedSrc,
      nameGen: () => 'ua',
    );
    MediaStore.overrideRootForTest(root.path); // simulate a restart

    final refs = await PendingAttachmentDao(db).referencedLocalPaths();
    final freed = await MediaStore.sweepOrphans(refs);

    expect(freed, 2, reason: 'only the abandoned file');
    expect(File(queued).existsSync(), isTrue);
    expect(File(abandoned).existsSync(), isFalse);
  });

  test('a FAILED referenced-set query must delete NOTHING', () async {
    // The guard that matters most. An empty set from a failed query would make
    // every staged file look reclaimable and wipe the user's queued work, so
    // the failure has to be distinguishable from "nothing is referenced".
    final src = File('${root.path}/s.jpg')..writeAsBytesSync([1]);
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'us');
    await PendingAttachmentDao(db).enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: staged,
    );
    MediaStore.overrideRootForTest(root.path);
    await db.execute('DROP TABLE pending_attachments');

    Set<String>? refs;
    try {
      refs = await PendingAttachmentDao(db).referencedLocalPaths();
    } catch (_) {
      refs = null; // what FrappeSDK._referencedStagedPaths returns
    }
    final freed = refs == null ? 0 : await MediaStore.sweepOrphans(refs);

    expect(freed, 0);
    expect(
      File(staged).existsSync(),
      isTrue,
      reason: 'a DB failure must never be read as "everything is an orphan"',
    );
  });

  test('usage counts a queued file as staged but NOT as reclaimable', () async {
    final src = File('${root.path}/u.jpg')
      ..writeAsBytesSync(List.filled(64, 0));
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'uu');
    await PendingAttachmentDao(db).enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: staged,
    );
    MediaStore.overrideRootForTest(root.path);

    final refs = await PendingAttachmentDao(db).referencedLocalPaths();
    final u = await MediaStore.usage(refs);

    expect(u.outboxBytes, 64);
    expect(u.orphanBytes, 0, reason: 'it is referenced, so not reclaimable');
    expect(u.orphanCount, 0);
    expect(u.totalBytes, 64);
  });
}
