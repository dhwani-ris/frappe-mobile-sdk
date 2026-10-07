// Field report: "Server rejected this form — BlockedByUpstream field=pic_1 …
// PathNotFoundException: Cannot retrieve length of file,
// path = '…/mform_attachments/outbox/<uuid>/335086.jpg'".
//
// The open form keeps the RAW staged path after a save (`hasInteractedByUser`
// pins it). If a push then uploads the attachment, `moveToCache` moves those
// bytes out of `outbox/`. The user is kept on the form whenever the push does
// not fully succeed (a server rejection of the doc, or a network drop after
// the attachment uploaded but before the doc POST), and re-submitting saves
// the same raw path again. `LocalWriter` drops the `done` row and enqueues a
// fresh `pending` one pointing at a file that no longer exists — the upload
// then fails with PathNotFoundException on every attempt, forever.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:frappe_mobile_sdk/src/sync/push_error.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  isTable: false,
  fields: [
    DocField(fieldname: 'title', fieldtype: 'Data'),
    DocField(fieldname: 'photo', fieldtype: 'Attach Image'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late OfflineRepository repo;
  late Directory root;
  late int uploads;

  AttachmentPipeline pipeline() => AttachmentPipeline(
    dao: PendingAttachmentDao(appDb.rawDatabase),
    db: appDb.rawDatabase,
    backoff: const [Duration.zero],
    tableNameFor: (dt) async => normalizeDoctypeTableName(dt),
    uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
      await file.length(); // what the real multipart upload does first
      uploads++;
      return {'file_url': '/private/files/$fileName', 'name': 'F-$uploads'};
    },
  );

  setUp(() async {
    uploads = 0;
    appDb = await AppDatabase.inMemoryDatabase();
    repo = OfflineRepository(
      appDb,
      localWriter: LocalWriter(appDb.rawDatabase, (_) async => _meta()),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      metaFetcher: (_) async => _meta(),
    );
    await appDb.doctypeMetaDao.upsertMetaJson(
      'Visit',
      jsonEncode(_meta().toJson()),
    );
    await repo.ensureSchemaForClosure(
      metas: {'Visit': _meta()},
      childDoctypes: const {},
    );
    root = await Directory.systemTemp.createTemp('resave_after_push');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
    await appDb.close();
  });

  test('re-saving the open form after its attachment uploaded does not '
      'queue a path that was moved to cache', () async {
    final src = File('${root.path}/335086.jpg')..createSync(recursive: true);
    await src.writeAsString('PHOTO');
    final stagedPath = await MediaStore.stageToOutbox(src);

    // 1. Submit #1: save, then push uploads the attachment.
    final uuid = await repo.saveDocument(
      doctype: 'Visit',
      data: {'title': 'Site A', 'photo': stagedPath},
    );
    await pipeline().resolveForTopParent(uuid);
    expect(uploads, 1);
    expect(
      File(stagedPath).existsSync(),
      isFalse,
      reason: 'precondition: the bytes moved to cache/',
    );
    // (the doc POST is rejected / drops here; the user stays on the form)

    // 2. Submit #2 from the SAME open form: the field still holds the raw
    //    staged path.
    await repo.saveDocument(
      doctype: 'Visit',
      data: {
        'mobile_uuid': uuid,
        'title': 'Site A (fixed)',
        'photo': stagedPath,
      },
    );

    // 3. The next push must not block on a missing file.
    await expectLater(pipeline().resolveForTopParent(uuid), completes);
    final row = (await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Visit'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    )).single;
    expect(row['photo'], '/private/files/335086.jpg');
  });

  test('a re-save that lands while the upload is in flight keeps the row '
      'the push is resolving', () async {
    final src = File('${root.path}/32412.jpg')..createSync(recursive: true);
    await src.writeAsString('PHOTO');
    final stagedPath = await MediaStore.stageToOutbox(src);
    final uuid = await repo.saveDocument(
      doctype: 'Visit',
      data: {'title': 'Site B', 'photo': stagedPath},
    );

    // The second tap's save runs between the upload and the cache move.
    final racing = AttachmentPipeline(
      dao: PendingAttachmentDao(appDb.rawDatabase),
      db: appDb.rawDatabase,
      backoff: const [Duration.zero],
      tableNameFor: (dt) async => normalizeDoctypeTableName(dt),
      uploader: (file, {doctype, docname, fileName, isPrivate = true}) async {
        await file.length();
        uploads++;
        await repo.saveDocument(
          doctype: 'Visit',
          data: {'mobile_uuid': uuid, 'title': 'Site B2', 'photo': stagedPath},
        );
        return {'file_url': '/private/files/$fileName', 'name': 'F-$uploads'};
      },
    );
    await racing.resolveForTopParent(uuid);

    // Nothing left to upload, and no row points at the moved file.
    final open = await PendingAttachmentDao(
      appDb.rawDatabase,
    ).findUnresolvedForTopParent(uuid);
    expect(open, isEmpty);
    await expectLater(pipeline().resolveForTopParent(uuid), completes);
    expect(uploads, 1);
    final row = (await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Visit'),
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    )).single;
    expect(row['photo'], '/private/files/32412.jpg');
    expect(row['title'], 'Site B2');
  });

  test('a queued file that is already gone is rejected with an actionable '
      'reason, not left failed to loop forever', () async {
    // The state devices hit by the old bug are already in: a pending row whose
    // staged file was moved away, with no recorded url.
    final src = File('${root.path}/225928.jpg')..createSync(recursive: true);
    await src.writeAsString('PHOTO');
    final stagedPath = await MediaStore.stageToOutbox(src);
    final uuid = await repo.saveDocument(
      doctype: 'Visit',
      data: {'title': 'Site D', 'photo': stagedPath},
    );
    File(stagedPath).deleteSync();

    await expectLater(
      pipeline().resolveForTopParent(uuid),
      throwsA(
        isA<BlockedByUpstream>().having(
          (e) => e.reason,
          'reason',
          contains('no longer on this device'),
        ),
      ),
    );
    final row = (await appDb.rawDatabase.query('pending_attachments')).single;
    expect(row['state'], 'rejected');
    expect(uploads, 0);
  });

  // A NEW record's identity rolls over after a successful local save
  // (`FormScreen._startNewDocumentIdentity`), so a re-submit from the open form
  // is saved under a fresh uuid while still carrying the first record's path.
  test('a re-save under a NEW uuid after the upload reuses its url', () async {
    final src = File('${root.path}/n1.jpg')..createSync(recursive: true);
    await src.writeAsString('PHOTO');
    final stagedPath = await MediaStore.stageToOutbox(src);
    final first = await repo.saveDocument(
      doctype: 'Visit',
      data: {'title': 'First', 'photo': stagedPath},
    );
    await pipeline().resolveForTopParent(first);

    final second = await repo.saveDocument(
      doctype: 'Visit',
      data: {'title': 'Second', 'photo': stagedPath},
    );

    await expectLater(pipeline().resolveForTopParent(second), completes);
    final row = (await appDb.rawDatabase.query(
      normalizeDoctypeTableName('Visit'),
      where: 'mobile_uuid = ?',
      whereArgs: [second],
    )).single;
    expect(row['photo'], '/private/files/n1.jpg');
    expect(uploads, 1);
  });

  test(
    'a re-save under a NEW uuid before the upload gets its own copy',
    () async {
      final src = File('${root.path}/n2.jpg')..createSync(recursive: true);
      await src.writeAsString('PHOTO');
      final stagedPath = await MediaStore.stageToOutbox(src);
      final first = await repo.saveDocument(
        doctype: 'Visit',
        data: {'title': 'First', 'photo': stagedPath},
      );
      final second = await repo.saveDocument(
        doctype: 'Visit',
        data: {'title': 'Second', 'photo': stagedPath},
      );

      // Two rows sharing one file would strand whichever pushes second: the
      // first upload moves the bytes.
      await pipeline().resolveForTopParent(first);
      await expectLater(pipeline().resolveForTopParent(second), completes);
      expect(uploads, 2);
    },
  );

  test('re-picking still replaces the queued row and frees its file', () async {
    final a = File('${root.path}/a.jpg')..createSync(recursive: true);
    await a.writeAsString('A');
    final pathA = await MediaStore.stageToOutbox(a);
    final uuid = await repo.saveDocument(
      doctype: 'Visit',
      data: {'title': 'Site C', 'photo': pathA},
    );
    final b = File('${root.path}/b.jpg')..createSync(recursive: true);
    await b.writeAsString('B');
    final pathB = await MediaStore.stageToOutbox(b);
    await repo.saveDocument(
      doctype: 'Visit',
      data: {'mobile_uuid': uuid, 'title': 'Site C', 'photo': pathB},
    );

    final queued = await appDb.rawDatabase.query('pending_attachments');
    expect(queued.single['local_path'], pathB);
    expect(File(pathA).existsSync(), isFalse);
  });
}
