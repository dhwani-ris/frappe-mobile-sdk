import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/models/pending_attachment.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeFile implements File {
  @override
  final String path;
  _FakeFile(this.path);
  @override
  noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late PendingAttachmentDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    dao = PendingAttachmentDao(db);
  });

  tearDown(() async => db.close());

  test(
    'uploads with NO doctype and NO docname (fully unattached File row)',
    () async {
      String? capturedDoctype;
      String? capturedDocname;

      await dao.enqueue(
        parentDoctype: 'Survey',
        parentUuid: 'survey-1',
        parentFieldname: 'cover',
        topParentUuid: 'survey-1',
        topParentDoctype: 'Survey',
        localPath: '/tmp/cover.jpg',
      );

      final pipeline = AttachmentPipeline(
        dao: dao,
        uploader: (file, {doctype, docname, isPrivate = true, fileName}) async {
          capturedDoctype = doctype;
          capturedDocname = docname;
          return {'name': 'FILE-1', 'file_url': '/private/files/cover.jpg'};
        },
        backoff: const [Duration.zero, Duration.zero, Duration.zero],
        fileFromPath: (p) => _FakeFile(p),
      );

      await pipeline.uploadPendingForTopParent('survey-1');

      expect(
        capturedDoctype,
        isNull,
        reason:
            'doctype must be null — Frappe v16 rejects File insert with '
            'attached_to_doctype set but attached_to_name empty/NULL '
            '(file.py:151), so the SDK uploads fully unattached.',
      );
      expect(
        capturedDocname,
        isNull,
        reason:
            'docname must be null — sentinel like "new-survey" creates '
            'orphaned File rows that the relink hooks cannot find.',
      );
    },
  );

  test(
    'uploads pending files, returns id→AttachmentUploadResult map',
    () async {
      final id1 = await dao.enqueue(
        parentDoctype: 'O',
        parentUuid: 'P',
        parentFieldname: 'attachment',
        topParentUuid: 'P',
        topParentDoctype: 'O',
        localPath: '/tmp/x.jpg',
      );
      final id2 = await dao.enqueue(
        parentDoctype: 'O',
        parentUuid: 'P',
        parentFieldname: 'attachment2',
        topParentUuid: 'P',
        topParentDoctype: 'O',
        localPath: '/tmp/y.jpg',
      );

      final pipeline = AttachmentPipeline(
        dao: dao,
        uploader: (file, {doctype, docname, isPrivate = true, fileName}) async {
          return {
            'name': 'FILE-${file.path}',
            'file_url': '/files${file.path}.url',
          };
        },
        backoff: const [Duration.zero, Duration.zero, Duration.zero],
        fileFromPath: (p) => _FakeFile(p),
      );

      final result = await pipeline.uploadPendingForTopParent('P');
      expect(result.keys, containsAll(<int>{id1, id2}));
      expect(result[id1]!.fileUrl, contains('/files'));
    },
  );

  test(
    'retries then throws BlockedByUpstream after exhausted attempts',
    () async {
      final id = await dao.enqueue(
        parentDoctype: 'O',
        parentUuid: 'P',
        parentFieldname: 'a',
        topParentUuid: 'P',
        topParentDoctype: 'O',
        localPath: '/tmp/fail.jpg',
      );
      var attempts = 0;
      final pipeline = AttachmentPipeline(
        dao: dao,
        uploader: (file, {doctype, docname, isPrivate = true, fileName}) async {
          attempts++;
          throw Exception('network');
        },
        backoff: const [Duration.zero, Duration.zero, Duration.zero],
        fileFromPath: (p) => _FakeFile(p),
      );
      await expectLater(
        pipeline.uploadPendingForTopParent('P'),
        throwsA(isA<BlockedByUpstream>()),
      );
      expect(attempts, 3);
      final row = await dao.findById(id);
      expect(row!.state, AttachmentState.failed);
    },
  );

  test('backoff uses indices 0..N-2 for N attempts (not 1..N-1)', () async {
    // Regression for PR#36 round-2 M1. Original code did
    // `backoff[attempt + 1]`, so with 3 attempts the second delay
    // reached index 2 — the would-be-30-seconds slot below. After the
    // fix the delays come from indices 0 and 1 only, both zero. We
    // give the call a 3-second timeout: before the fix this trips
    // (we'd sleep 30s); after the fix the call completes in ms.
    await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'P',
      parentFieldname: 'a',
      topParentUuid: 'P',
      topParentDoctype: 'O',
      localPath: '/tmp/fail.jpg',
    );
    var attempts = 0;
    final pipeline = AttachmentPipeline(
      dao: dao,
      uploader: (file, {doctype, docname, isPrivate = true, fileName}) async {
        attempts++;
        throw Exception('network');
      },
      backoff: const [Duration.zero, Duration.zero, Duration(seconds: 30)],
      fileFromPath: (p) => _FakeFile(p),
    );
    await expectLater(
      pipeline
          .uploadPendingForTopParent('P')
          .timeout(const Duration(seconds: 3)),
      throwsA(isA<BlockedByUpstream>()),
    );
    expect(attempts, 3);
  });

  test('inlinePayload rewrites pending:<id> markers with file_url', () async {
    final payload = <String, Object?>{
      'doctype': 'O',
      'name': null,
      'logo': 'pending:1',
      'other_field': 'unchanged',
    };
    final out = AttachmentPipeline.inlinePayload(
      payload,
      resolved: {
        1: const AttachmentUploadResult(fileName: 'X', fileUrl: '/files/X'),
      },
    );
    expect(out['logo'], '/files/X');
    expect(out['other_field'], 'unchanged');
  });

  test('inlinePayload walks into children lists', () {
    final payload = <String, Object?>{
      'items': [
        {'photo': 'pending:2', 'qty': 1},
      ],
    };
    final out = AttachmentPipeline.inlinePayload(
      payload,
      resolved: {
        2: const AttachmentUploadResult(fileName: 'Y', fileUrl: '/files/Y'),
      },
    );
    expect((out['items'] as List).first['photo'], '/files/Y');
  });

  test(
    'inlinePayload leaves pending:<id> alone when the id has no resolved entry',
    () {
      final payload = <String, Object?>{'logo': 'pending:42'};
      final out = AttachmentPipeline.inlinePayload(payload, resolved: {});
      expect(out['logo'], 'pending:42');
    },
  );
}
