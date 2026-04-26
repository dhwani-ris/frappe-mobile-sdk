import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/pending_attachment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late PendingAttachmentDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
    dao = PendingAttachmentDao(db);
  });

  tearDown(() async => db.close());

  test('enqueue returns id, starts as pending', () async {
    final id = await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'u',
      parentFieldname: 'attachment',
      localPath: '/tmp/foo.jpg',
      fileName: 'foo.jpg',
      mimeType: 'image/jpeg',
      isPrivate: true,
    );
    expect(id, greaterThan(0));
    final r = await dao.findById(id);
    expect(r!.state, AttachmentState.pending);
  });

  test('findPendingForParent returns matching rows', () async {
    await dao.enqueue(
      parentDoctype: 'O', parentUuid: 'p1', parentFieldname: 'a',
      localPath: '/x.jpg',
    );
    await dao.enqueue(
      parentDoctype: 'O', parentUuid: 'p2', parentFieldname: 'a',
      localPath: '/y.jpg',
    );
    final rows = await dao.findPendingForParent('p1');
    expect(rows.length, 1);
    expect(rows.first.parentUuid, 'p1');
  });

  test('markUploading → markDone persists server info', () async {
    final id = await dao.enqueue(
      parentDoctype: 'O', parentUuid: 'p', parentFieldname: 'a',
      localPath: '/x.jpg',
    );
    await dao.markUploading(id);
    expect((await dao.findById(id))!.state, AttachmentState.uploading);
    await dao.markDone(id,
        serverFileName: 'FILE-1', serverFileUrl: '/files/FILE-1.jpg');
    final done = await dao.findById(id);
    expect(done!.state, AttachmentState.done);
    expect(done.serverFileUrl, '/files/FILE-1.jpg');
  });

  test('markFailed increments retry_count', () async {
    final id = await dao.enqueue(
      parentDoctype: 'O', parentUuid: 'p', parentFieldname: 'a',
      localPath: '/x.jpg',
    );
    await dao.markFailed(id, errorMessage: 'network');
    await dao.markFailed(id, errorMessage: 'network');
    final r = await dao.findById(id);
    expect(r!.state, AttachmentState.failed);
    expect(r.retryCount, 2);
  });
}
