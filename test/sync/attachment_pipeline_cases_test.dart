import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/exceptions.dart';
import 'package:frappe_mobile_sdk/src/database/daos/media_cache_dao.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/pending_attachment.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Covers the case matrix in the design spec §7. Every case asserts the
/// uploader CALL COUNT, because "no duplicate uploads" is a claim about
/// invocations, not just about outcomes.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late PendingAttachmentDao dao;
  late Directory root;
  var uploadCalls = 0;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    await db.execute('''
      CREATE TABLE docs__order (
        mobile_uuid TEXT PRIMARY KEY, server_name TEXT, photo TEXT, title TEXT
      )
    ''');
    await db.insert('docs__order', {'mobile_uuid': 'P1', 'photo': null});
    dao = PendingAttachmentDao(db);
    root = await Directory.systemTemp.createTemp('pipecases');
    MediaStore.overrideRootForTest(root.path);
    uploadCalls = 0;
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<int> enqueue({String content = 'A'}) async {
    final src = File('${root.path}/pick.jpg')..writeAsStringSync(content);
    final staged = await MediaStore.stageToOutbox(src, nameGen: () => 'stg');
    final id = await dao.enqueue(
      parentDoctype: 'Order',
      parentUuid: 'P1',
      parentFieldname: 'photo',
      topParentUuid: 'P1',
      topParentDoctype: 'Order',
      localPath: staged,
      fileName: 'pick.jpg',
    );
    await db.update(
      'docs__order',
      {'photo': 'pending:$id'},
      where: 'mobile_uuid = ?',
      whereArgs: ['P1'],
    );
    return id;
  }

  AttachmentPipeline pipeline({
    Future<Map<String, dynamic>> Function()? onUpload,
    List<Duration> backoff = const [
      Duration.zero,
      Duration.zero,
      Duration.zero,
    ],
  }) {
    return AttachmentPipeline(
      dao: dao,
      db: db,
      backoff: backoff,
      tableNameFor: (dt) async => dt == 'Order' ? 'docs__order' : null,
      uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
        uploadCalls++;
        if (onUpload != null) return onUpload();
        return {'file_url': '/files/ok.jpg', 'name': 'ok.jpg'};
      },
    );
  }

  Future<String?> photoColumn() async =>
      (await db.query('docs__order')).single['photo'] as String?;

  test('case 1: happy path writes the url back and caches the bytes', () async {
    await enqueue();
    final out = await pipeline().resolveForTopParent('P1');

    expect(uploadCalls, 1);
    expect(out.values.single.fileUrl, '/files/ok.jpg');
    expect(
      await photoColumn(),
      '/files/ok.jpg',
      reason: 'writeback must replace the marker in docs__',
    );

    final cached = await MediaCacheDao(db).findByUrl('/files/ok.jpg');
    expect(cached, isNotNull, reason: 'uploaded bytes become the cache entry');
    expect(File(cached!.localPath).existsSync(), isTrue);
    expect(cached.source.name, 'uploaded');
  });

  test('case 2: a committed url means NO second upload', () async {
    final id = await enqueue();
    // Simulate a crash after recordUpload but before the step-4 txn.
    await dao.recordUpload(
      id,
      serverFileName: 'ok.jpg',
      serverFileUrl: '/files/ok.jpg',
    );
    await dao.markUploading(id);

    await pipeline().resolveForTopParent('P1');

    expect(
      uploadCalls,
      0,
      reason: 'a committed url is terminal — never re-upload',
    );
    expect(await photoColumn(), '/files/ok.jpg');
  });

  test(
    'case 5: a retry after a failed parent push does no work at all',
    () async {
      await enqueue();
      await pipeline().resolveForTopParent('P1');
      expect(uploadCalls, 1);

      // The parent POST failed; the user retried. The column already holds the
      // real url, so there is nothing left to resolve.
      final out2 = await pipeline().resolveForTopParent('P1');
      expect(uploadCalls, 1, reason: 'no re-upload on a parent-push retry');
      expect(out2, isEmpty, reason: 'nothing outstanding');
      expect(await photoColumn(), '/files/ok.jpg');
    },
  );

  test(
    'case 6: terminal rejection blocks the push and never auto-retries',
    () async {
      await enqueue();
      final p = pipeline(
        onUpload: () async => throw ValidationException(
          'File size exceeded the maximum',
          {'exc_type': 'MaxFileSizeReachedError'},
        ),
      );

      await expectLater(
        p.resolveForTopParent('P1'),
        throwsA(isA<BlockedByUpstream>()),
      );
      expect(
        (await dao.findAllForTopParent('P1')).single.state,
        AttachmentState.rejected,
      );
      final callsAfterFirst = uploadCalls;

      // The user taps retry. It must STILL block, and must NOT upload again.
      await expectLater(
        pipeline().resolveForTopParent('P1'),
        throwsA(isA<BlockedByUpstream>()),
      );
      expect(
        uploadCalls,
        callsAfterFirst,
        reason: 'terminal rejection is never auto-retried',
      );
      expect(
        await photoColumn(),
        startsWith('pending:'),
        reason: 'the marker must NOT reach the wire — the push is blocked',
      );
    },
  );

  test(
    'case 6b: a transient failure blocks now but retries next dispatch',
    () async {
      await enqueue();
      await expectLater(
        pipeline(
          onUpload: () async => throw NetworkException('socket closed'),
        ).resolveForTopParent('P1'),
        throwsA(isA<BlockedByUpstream>()),
      );
      expect(
        (await dao.findAllForTopParent('P1')).single.state,
        AttachmentState.failed,
      );

      final before = uploadCalls;
      await pipeline().resolveForTopParent('P1');
      expect(
        uploadCalls,
        greaterThan(before),
        reason: 'transient rows are re-armed',
      );
      expect(await photoColumn(), '/files/ok.jpg');
    },
  );

  test(
    'a transient failure retries within one dispatch before giving up',
    () async {
      await enqueue();
      await expectLater(
        pipeline(
          onUpload: () async => throw NetworkException('down'),
        ).resolveForTopParent('P1'),
        throwsA(isA<BlockedByUpstream>()),
      );
      expect(uploadCalls, 3, reason: 'three backoff slots, three attempts');
    },
  );

  test('the blocked error names the file and field, not a row id', () async {
    await enqueue();
    try {
      await pipeline(
        onUpload: () async => throw ValidationException('too big', {
          'exc_type': 'MaxFileSizeReachedError',
        }),
      ).resolveForTopParent('P1');
      fail('expected BlockedByUpstream');
    } on BlockedByUpstream catch (e) {
      expect(e.message, contains('pick.jpg'));
      expect(e.message, contains('photo'));
    }
  });

  test('the resolution map includes done rows so an interrupted writeback '
      'still resolves', () async {
    final id = await enqueue();
    await pipeline().resolveForTopParent('P1');
    // Simulate the writeback having been lost while the row is already done.
    await db.update(
      'docs__order',
      {'photo': 'pending:$id'},
      where: 'mobile_uuid = ?',
      whereArgs: ['P1'],
    );

    final map = await pipeline().resolutionMapFor('P1');
    expect(map[id]?.fileUrl, '/files/ok.jpg');
    final out = AttachmentPipeline.inlinePayload({
      'photo': 'pending:$id',
    }, resolved: map);
    expect(out['photo'], '/files/ok.jpg');
  });

  group('inlinePayload', () {
    test('throws on an unresolved marker instead of shipping it', () {
      expect(
        () => AttachmentPipeline.inlinePayload({
          'photo': 'pending:99',
        }, resolved: const {}),
        throwsA(isA<StateError>()),
      );
    });

    test('throws on an unresolved marker nested in a child row', () {
      expect(
        () => AttachmentPipeline.inlinePayload({
          'items': [
            {'receipt': 'pending:42'},
          ],
        }, resolved: const {}),
        throwsA(isA<StateError>()),
      );
    });

    test('leaves ordinary values untouched', () {
      final out = AttachmentPipeline.inlinePayload({
        'title': 'plain',
        'photo': '/files/already.jpg',
        'count': 3,
      }, resolved: const {});
      expect(out['title'], 'plain');
      expect(out['photo'], '/files/already.jpg');
      expect(out['count'], 3);
    });
  });

  group('the writeback must not clobber a value the user changed', () {
    test('a field discarded mid-upload is NOT resurrected', () async {
      await enqueue();
      // The window that matters: the gate has read the row and the upload is
      // in flight when the user discards. The column is cleared while the row
      // is still present, so the dispatch runs to completion and writes back.
      await db.update(
        'docs__order',
        {'photo': null},
        where: 'mobile_uuid = ?',
        whereArgs: ['P1'],
      );

      await pipeline().resolveForTopParent('P1');

      expect(
        await photoColumn(),
        isNull,
        reason: 'a completed upload must not restore a discarded attachment',
      );
    });

    test('a re-pick mid-upload is NOT overwritten by the old upload', () async {
      final first = await enqueue();
      // User re-picks: the column now points at a DIFFERENT pending row.
      await db.update(
        'docs__order',
        {'photo': 'pending:${first + 99}'},
        where: 'mobile_uuid = ?',
        whereArgs: ['P1'],
      );

      await pipeline().resolveForTopParent('P1');

      expect(
        await photoColumn(),
        'pending:${first + 99}',
        reason: "the old upload must not claim the new pick's slot",
      );
    });

    test('the normal path still writes back', () async {
      await enqueue();
      await pipeline().resolveForTopParent('P1');
      expect(await photoColumn(), '/files/ok.jpg');
    });
  });
}
