import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
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

  test('uploadPendingForTopParent uploads BOTH parent-field and '
      'child-row attachments belonging to the same outbox row', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    final dao = PendingAttachmentDao(db);

    await dao.enqueue(
      parentDoctype: 'Survey',
      parentUuid: 'survey-1',
      parentFieldname: 'cover',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/cover.jpg',
    );
    await dao.enqueue(
      parentDoctype: 'Survey Item',
      parentUuid: 'item-1', // child-row uuid (different from top parent)
      parentFieldname: 'photo',
      topParentUuid: 'survey-1',
      topParentDoctype: 'Survey',
      localPath: '/tmp/item-1.jpg',
    );

    final capturedPaths = <String>[];
    final capturedDoctypes = <String?>[];
    final pipeline = AttachmentPipeline(
      dao: dao,
      uploader: (file, {doctype, docname, isPrivate = true, fileName}) async {
        capturedPaths.add(file.path);
        capturedDoctypes.add(doctype);
        return {
          'name': 'FILE-${file.path}',
          'file_url': '/private/files${file.path}',
        };
      },
      backoff: const [Duration.zero, Duration.zero, Duration.zero],
      fileFromPath: (p) => _FakeFile(p),
    );

    final result = await pipeline.uploadPendingForTopParent('survey-1');

    expect(result, hasLength(2));
    expect(capturedPaths, containsAll(['/tmp/cover.jpg', '/tmp/item-1.jpg']));
    // SDK uploads with no doctype (v16 rejects partial-attach Files);
    // each child / parent attachment is uploaded fully unattached.
    expect(capturedDoctypes.every((d) => d == null), isTrue);

    await db.close();
  });
}
