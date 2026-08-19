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
    // Without this the store falls back to getApplicationDocumentsDirectory(),
    // which needs a platform channel that plain `flutter test` cannot provide.
    storeRoot = await Directory.systemTemp.createTemp('cleanupstore');
    MediaStore.overrideRootForTest(storeRoot.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await storeRoot.exists()) await storeRoot.delete(recursive: true);
  });

  // The staged copy is now MOVED into the cache rather than deleted: media this
  // device created becomes its own cache entry, so it never re-downloads.
  // Either way the outbox copy must not survive.
  test('the staged copy leaves outbox/ after a successful upload', () async {
    final tmp = await Directory.systemTemp.createTemp('attach');
    final localFile = File('${tmp.path}/photo.jpg')..writeAsStringSync('IMG');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: localFile.path,
      fileName: 'photo.jpg',
    );

    final pipeline = AttachmentPipeline(
      dao: dao,
      db: db,
      uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
        return {'file_url': '/files/photo.jpg', 'name': 'photo.jpg'};
      },
    );

    final results = await pipeline.resolveForTopParent('P1');

    expect(results.length, 1);
    expect(
      localFile.existsSync(),
      isFalse,
      reason: 'the staged copy must not survive the upload',
    );

    // ...and it was relocated, not destroyed: the bytes are now the cache
    // entry for their file_url, so a preview never re-downloads them.
    final cached = File(await MediaStore.cachePathFor('/files/photo.jpg'));
    expect(cached.existsSync(), isTrue);
    expect(cached.readAsStringSync(), 'IMG');

    final rows = await db.query('pending_attachments');
    expect(rows.single['state'], 'done');
  });

  test('a failed cache move still reclaims the staged copy', () async {
    final tmp = await Directory.systemTemp.createTemp('attach_nocache');
    final localFile = File('${tmp.path}/photo.jpg')..writeAsStringSync('IMG');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P2',
      parentFieldname: 'photo',
      topParentUuid: 'P2',
      topParentDoctype: 'Order',
      localPath: localFile.path,
      fileName: 'photo.jpg',
    );

    // Put a FILE where the store root's directory must go, so creating the
    // cache/ subdirectory fails and the move cannot complete.
    final blocker = File('${storeRoot.path}/blocked')..writeAsStringSync('x');
    MediaStore.overrideRootForTest(blocker.path);

    final pipeline = AttachmentPipeline(
      dao: dao,
      db: db,
      uploader: (file, {doctype, docname, fileName, isPrivate = true}) async =>
          {'file_url': '/files/photo2.jpg', 'name': 'photo2.jpg'},
    );

    await pipeline.resolveForTopParent('P2');

    // The bytes are on the server, so a staged copy left behind would be an
    // unreferenced leak that nothing else reclaims.
    expect(localFile.existsSync(), isFalse);
    expect((await db.query('pending_attachments')).single['state'], 'done');
  });
}
