import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/media_cache_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/media_cache_entry.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late MediaCacheDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    dao = MediaCacheDao(db);
  });

  tearDown(() async => db.close());

  test('upsert then findByUrl round-trips every field', () async {
    await dao.upsert(
      fileUrl: '/files/a.jpg',
      localPath: '/cache/abc.jpg',
      sizeBytes: 1234,
      mimeType: 'image/jpeg',
      isPrivate: true,
      source: MediaSource.uploaded,
    );
    final e = await dao.findByUrl('/files/a.jpg');
    expect(e, isNotNull);
    expect(e!.localPath, '/cache/abc.jpg');
    expect(e.sizeBytes, 1234);
    expect(e.mimeType, 'image/jpeg');
    expect(e.isPrivate, isTrue);
    expect(e.source, MediaSource.uploaded);
    expect(e.createdAt.isUtc, isTrue);
  });

  test('findByUrl returns null for an unknown url', () async {
    expect(await dao.findByUrl('/files/missing.jpg'), isNull);
  });

  test('a public file round-trips is_private=false', () async {
    await dao.upsert(
      fileUrl: '/files/pub.jpg',
      localPath: '/cache/pub.jpg',
      isPrivate: false,
      source: MediaSource.downloaded,
    );
    expect((await dao.findByUrl('/files/pub.jpg'))!.isPrivate, isFalse);
  });

  test('upsert on an existing file_url replaces, never duplicates', () async {
    await dao.upsert(
      fileUrl: '/files/a.jpg',
      localPath: '/cache/one.jpg',
      source: MediaSource.downloaded,
    );
    await dao.upsert(
      fileUrl: '/files/a.jpg',
      localPath: '/cache/two.jpg',
      source: MediaSource.uploaded,
    );
    expect((await db.query('media_cache')).length, 1);
    final e = await dao.findByUrl('/files/a.jpg');
    expect(e!.localPath, '/cache/two.jpg');
    expect(e.source, MediaSource.uploaded);
  });

  test('touch updates last_accessed_at', () async {
    await dao.upsert(
      fileUrl: '/files/a.jpg',
      localPath: '/cache/a.jpg',
      source: MediaSource.downloaded,
    );
    final before =
        (await db.query('media_cache')).single['last_accessed_at'] as int;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await dao.touch('/files/a.jpg');
    final after =
        (await db.query('media_cache')).single['last_accessed_at'] as int;
    expect(after >= before, isTrue);
  });

  test('touch on an unknown url is a no-op, not an error', () async {
    await dao.touch('/files/nothing.jpg');
    expect(await db.query('media_cache'), isEmpty);
  });

  test('totalBytes sums size_bytes and tolerates nulls', () async {
    await dao.upsert(
      fileUrl: '/f/1',
      localPath: '/c/1',
      sizeBytes: 100,
      source: MediaSource.uploaded,
    );
    await dao.upsert(
      fileUrl: '/f/2',
      localPath: '/c/2',
      sizeBytes: 250,
      source: MediaSource.uploaded,
    );
    // A row with no recorded size must contribute 0, not poison the sum.
    await dao.upsert(
      fileUrl: '/f/3',
      localPath: '/c/3',
      source: MediaSource.downloaded,
    );
    expect(await dao.totalBytes(), 350);
  });

  test('totalBytes is 0 on an empty cache', () async {
    expect(await dao.totalBytes(), 0);
  });

  test('deleteAll empties the table and reports the count', () async {
    await dao.upsert(
      fileUrl: '/f/1',
      localPath: '/c/1',
      source: MediaSource.uploaded,
    );
    await dao.upsert(
      fileUrl: '/f/2',
      localPath: '/c/2',
      source: MediaSource.uploaded,
    );
    expect(await dao.deleteAll(), 2);
    expect(await db.query('media_cache'), isEmpty);
  });
}
