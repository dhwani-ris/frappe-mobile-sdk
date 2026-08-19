import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/media_cache_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/media_cache_entry.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late PendingAttachmentDao dao;
  late Directory root;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    dao = PendingAttachmentDao(db);
    root = await Directory.systemTemp.createTemp('reclaim');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<String> stage(String name) async {
    final src = File('${root.path}/$name')..writeAsStringSync('X');
    return MediaStore.stageToOutbox(src, nameGen: () => name);
  }

  test('deleting queued attachments removes their staged files', () async {
    final path = await stage('a.jpg');
    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: path,
    );
    expect(File(path).existsSync(), isTrue);

    final removed = await dao.deleteForTopParent('P1');

    expect(removed, 1);
    expect(
      File(path).existsSync(),
      isFalse,
      reason:
          'staged bytes must not outlive their row — nothing else '
          'reclaims outbox/',
    );
    expect(await db.query('pending_attachments'), isEmpty);
  });

  test('deleteForTopParent clears child-row attachments too', () async {
    final parentPath = await stage('parent.jpg');
    final childPath = await stage('child.jpg');
    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: parentPath,
    );
    await dao.enqueue(
      parentDoctype: 'Order Item',
      parentUuid: 'C1',
      parentFieldname: 'receipt',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: childPath,
    );

    await dao.deleteForTopParent('P1');

    expect(File(parentPath).existsSync(), isFalse);
    expect(File(childPath).existsSync(), isFalse);
  });

  test('deleteForTopParent leaves other documents untouched', () async {
    final mine = await stage('mine.jpg');
    final theirs = await stage('theirs.jpg');
    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: mine,
    );
    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P2',
      parentFieldname: 'photo',
      topParentUuid: 'P2',
      topParentDoctype: 'Order',
      localPath: theirs,
    );

    await dao.deleteForTopParent('P1');

    expect(File(mine).existsSync(), isFalse);
    expect(File(theirs).existsSync(), isTrue);
    expect((await db.query('pending_attachments')).length, 1);
  });

  test('deleteForTopParent tolerates an already-missing file', () async {
    final path = await stage('b.jpg');
    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P2',
      parentFieldname: 'photo',
      topParentUuid: 'P2',
      topParentDoctype: 'Order',
      localPath: path,
    );
    File(path).deleteSync();

    await dao.deleteForTopParent('P2');

    expect(await db.query('pending_attachments'), isEmpty);
  });

  test('deleteForTopParent does NOT touch the media cache', () async {
    // Cached bytes are keyed by file_url and may be shared with other
    // documents; their lifetime is governed by eviction and wipe only.
    final cacheDao = MediaCacheDao(db);
    final cachedFile = File('${root.path}/cached.jpg')..writeAsStringSync('C');
    await cacheDao.upsert(
      fileUrl: '/files/shared.jpg',
      localPath: cachedFile.path,
      source: MediaSource.downloaded,
    );

    final path = await stage('c.jpg');
    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P3',
      parentFieldname: 'photo',
      topParentUuid: 'P3',
      topParentDoctype: 'Order',
      localPath: path,
    );

    await dao.deleteForTopParent('P3');

    expect(await cacheDao.findByUrl('/files/shared.jpg'), isNotNull);
    expect(cachedFile.existsSync(), isTrue);
  });
}
