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

  test('uploads pending files, returns id→AttachmentUploadResult map', () async {
    final id1 = await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'P',
      parentFieldname: 'attachment',
      localPath: '/tmp/x.jpg',
    );
    final id2 = await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'P',
      parentFieldname: 'attachment2',
      localPath: '/tmp/y.jpg',
    );

    final pipeline = AttachmentPipeline(
      dao: dao,
      uploader:
          (file, {doctype, docname, isPrivate = true, fileName}) async {
        return {
          'name': 'FILE-${file.path}',
          'file_url': '/files${file.path}.url',
        };
      },
      backoff: const [Duration.zero, Duration.zero, Duration.zero],
      fileFromPath: (p) => _FakeFile(p),
    );

    final result = await pipeline.uploadPendingFor('P');
    expect(result.keys, containsAll(<int>{id1, id2}));
    expect(result[id1]!.fileUrl, contains('/files'));
  });

  test('retries then throws BlockedByUpstream after exhausted attempts',
      () async {
    final id = await dao.enqueue(
      parentDoctype: 'O',
      parentUuid: 'P',
      parentFieldname: 'a',
      localPath: '/tmp/fail.jpg',
    );
    var attempts = 0;
    final pipeline = AttachmentPipeline(
      dao: dao,
      uploader:
          (file, {doctype, docname, isPrivate = true, fileName}) async {
        attempts++;
        throw Exception('network');
      },
      backoff: const [Duration.zero, Duration.zero, Duration.zero],
      fileFromPath: (p) => _FakeFile(p),
    );
    await expectLater(
      pipeline.uploadPendingFor('P'),
      throwsA(isA<BlockedByUpstream>()),
    );
    expect(attempts, 3);
    final row = await dao.findById(id);
    expect(row!.state, AttachmentState.failed);
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
      final payload = <String, Object?>{
        'logo': 'pending:42',
      };
      final out = AttachmentPipeline.inlinePayload(payload, resolved: {});
      expect(out['logo'], 'pending:42');
    },
  );
}
