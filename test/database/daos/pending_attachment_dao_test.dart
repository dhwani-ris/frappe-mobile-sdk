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
      topParentUuid: 'u',
      topParentDoctype: 'Order',
      localPath: '/tmp/foo.jpg',
      fileName: 'foo.jpg',
      mimeType: 'image/jpeg',
      isPrivate: true,
    );
    expect(id, greaterThan(0));
    final r = await dao.findById(id);
    expect(r!.state, AttachmentState.pending);
  });

  test('findUnresolvedForTopParent returns matching rows', () async {
    await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'p1',
      parentFieldname: 'a',
      topParentUuid: 'p1',
      topParentDoctype: 'O',
      localPath: '/x.jpg',
    );
    await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'p2',
      parentFieldname: 'a',
      topParentUuid: 'p2',
      topParentDoctype: 'O',
      localPath: '/y.jpg',
    );
    final rows = await dao.findUnresolvedForTopParent('p1');
    expect(rows.length, 1);
    expect(rows.first.parentUuid, 'p1');
  });

  test('findUnresolvedForTopParent finds attachments queued against parent '
      'AND against children of that parent', () async {
    final aParent = await dao.enqueue(
      parentDoctype: 'Survey',
      parentUuid: 'survey-1',
      parentFieldname: 'cover',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/cover.jpg',
    );
    final aChild = await dao.enqueue(
      parentDoctype: 'Survey Item',
      parentUuid: 'item-1',
      parentFieldname: 'photo',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/item.jpg',
    );
    await dao.enqueue(
      parentDoctype: 'Survey',
      parentUuid: 'survey-2',
      parentFieldname: 'cover',
      topParentUuid: 'survey-2',
      topParentDoctype: 'Survey',
      localPath: '/tmp/other.jpg',
    );

    final rows = await dao.findUnresolvedForTopParent('survey-1');
    final ids = rows.map((r) => r.id).toSet();
    expect(ids, {aParent, aChild});
  });

  test('markUploading → markDone persists server info', () async {
    final id = await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'p',
      parentFieldname: 'a',
      topParentUuid: 'p',
      topParentDoctype: 'O',
      localPath: '/x.jpg',
    );
    await dao.markUploading(id);
    expect((await dao.findById(id))!.state, AttachmentState.uploading);
    await dao.markDone(
      id,
      serverFileName: 'FILE-1',
      serverFileUrl: '/files/FILE-1.jpg',
    );
    final done = await dao.findById(id);
    expect(done!.state, AttachmentState.done);
    expect(done.serverFileUrl, '/files/FILE-1.jpg');
  });

  test('markFailed increments retry_count', () async {
    final id = await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'p',
      parentFieldname: 'a',
      topParentUuid: 'p',
      topParentDoctype: 'O',
      localPath: '/x.jpg',
    );
    await dao.markFailed(id, errorMessage: 'network');
    await dao.markFailed(id, errorMessage: 'network');
    final r = await dao.findById(id);
    expect(r!.state, AttachmentState.failed);
    expect(r.retryCount, 2);
  });

  test(
    'PendingAttachment.fromMap parses top_parent_uuid + top_parent_doctype',
    () async {
      final id = await dao.enqueue(
        parentDoctype: 'Survey Item',
        parentUuid: 'child-1',
        parentFieldname: 'photo',
        topParentUuid: 'survey-7',
        topParentDoctype: 'Survey',
        localPath: '/tmp/p.jpg',
      );
      final row = await dao.findById(id);
      expect(row!.parentUuid, 'child-1');
      expect(row.parentDoctype, 'Survey Item');
      expect(row.topParentUuid, 'survey-7');
      expect(row.topParentDoctype, 'Survey');
    },
  );

  test('findUnresolvedForTopParent returns every non-done state', () async {
    final ids = <int>[];
    for (var i = 0; i < 4; i++) {
      ids.add(
        await dao.enqueue(
          parentDoctype: 'Order',
          parentUuid: 'P1',
          parentFieldname: 'f$i',
          topParentUuid: 'P1',
          topParentDoctype: 'Order',
          localPath: '/tmp/f$i',
        ),
      );
    }
    await dao.markUploading(ids[1]);
    await dao.markDone(ids[2], serverFileName: 'n', serverFileUrl: '/files/n');
    await dao.markRejected(ids[3], errorMessage: 'too large');

    final unresolved = await dao.findUnresolvedForTopParent('P1');
    expect(unresolved.map((r) => r.id), containsAll([ids[0], ids[1], ids[3]]));
    expect(
      unresolved.map((r) => r.id),
      isNot(contains(ids[2])),
      reason: 'done rows have no outstanding work',
    );

    final all = await dao.findAllForTopParent('P1');
    expect(all.length, 4, reason: 'the resolution map needs done rows too');
  });

  test('markRejected is terminal and records an actionable reason', () async {
    final id = await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: '/tmp/a',
    );
    await dao.markRejected(id, errorMessage: 'File size exceeded');
    final row = (await dao.findById(id))!;
    expect(row.state, AttachmentState.rejected);
    expect(row.errorMessage, 'File size exceeded');
    expect(row.retryCount, 1);
  });

  test('a rejected row still blocks: it is returned as unresolved', () async {
    final id = await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: '/tmp/a',
    );
    await dao.markRejected(id, errorMessage: 'nope');
    final unresolved = await dao.findUnresolvedForTopParent('P1');
    expect(
      unresolved.single.id,
      id,
      reason: 'silently skipping it is what shipped a raw marker to Frappe',
    );
  });

  test('referencedLocalPaths returns paths from rows in EVERY state', () async {
    // A failed or rejected row still owns its file — the user can retry or
    // replace it. Only `done` rows have had their bytes moved to the cache, and
    // even those must not be swept while the row exists.
    final ids = <int>[];
    for (var i = 0; i < 4; i++) {
      ids.add(
        await dao.enqueue(
          parentDoctype: 'Order',
          parentUuid: 'P1',
          parentFieldname: 'f$i',
          topParentUuid: 'P1',
          topParentDoctype: 'Order',
          localPath: '/outbox/u$i/file$i.jpg',
        ),
      );
    }
    await dao.markUploading(ids[1]);
    await dao.markFailed(ids[2], errorMessage: 'net');
    await dao.markRejected(ids[3], errorMessage: 'too big');

    expect(await dao.referencedLocalPaths(), {
      '/outbox/u0/file0.jpg',
      '/outbox/u1/file1.jpg',
      '/outbox/u2/file2.jpg',
      '/outbox/u3/file3.jpg',
    });
  });

  test('referencedLocalPaths is empty when nothing is queued', () async {
    expect(await dao.referencedLocalPaths(), isEmpty);
  });
}
