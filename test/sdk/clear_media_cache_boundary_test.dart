import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/media_cache_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/media_cache_entry.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The most important API boundary in this feature: a host wires
/// "Clear cached media" to a button, and it must be impossible for that button
/// to destroy an un-uploaded attachment.
///
/// Exercises the composition `FrappeSDK.clearMediaCache()` performs, because
/// constructing a real SDK needs a full `initialize()` with a live client.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'clearing the cache spares outbox files AND pending_attachments rows',
    () async {
      final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      for (final s in systemTablesDDL()) {
        await db.execute(s);
      }
      final root = await Directory.systemTemp.createTemp('clearboundary');
      MediaStore.overrideRootForTest(root.path);
      addTearDown(() async {
        MediaStore.overrideRootForTest(null);
        await db.close();
        if (await root.exists()) await root.delete(recursive: true);
      });

      // An un-uploaded attachment: staged bytes plus the row that owns them.
      final src = File('${root.path}/photo.jpg')..writeAsStringSync('USERDATA');
      final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'uid1');
      await PendingAttachmentDao(db).enqueue(
        parentDoctype: 'Order',
        parentUuid: 'P1',
        parentFieldname: 'photo',
        topParentUuid: 'P1',
        topParentDoctype: 'Order',
        localPath: staged,
      );

      // A cached preview of server media.
      final cache = MediaCacheDao(db);
      final cached = File('${root.path}/c.jpg')..writeAsStringSync('C');
      final cachedStaged = await MediaStore.stageToOutbox(
        cached,
        nameGen: () => 'uid2',
      );
      await MediaStore.moveToCache(cachedStaged, '/files/c.jpg');
      await cache.upsert(
        fileUrl: '/files/c.jpg',
        localPath: await MediaStore.cachePathFor('/files/c.jpg'),
        source: MediaSource.downloaded,
      );

      // What FrappeSDK.clearMediaCache() does.
      await MediaStore.clearCache();
      await cache.deleteAll();

      expect(
        File(staged).existsSync(),
        isTrue,
        reason: 'the only copy of an un-uploaded attachment must survive',
      );
      expect(
        (await db.query('pending_attachments')).length,
        1,
        reason: 'the row that owns it must survive too',
      );
      expect(await db.query('media_cache'), isEmpty);
      expect(
        File(await MediaStore.cachePathFor('/files/c.jpg')).existsSync(),
        isFalse,
      );
    },
  );
}
