// Two guards for an attach field still holding a raw staged path at save time.
//
// Offline: once the push uploaded the file, a re-save from the open form must
// carry the server url, not the path whose bytes were moved to cache/.
// Online: the save is HTTP-only and never reaches LocalWriter, so a pick whose
// inline upload failed used to POST `/data/user/0/.../outbox/<uuid>/x.jpg`
// verbatim as the field's value.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/pending_attachment_dao.dart';
import 'package:frappe_mobile_sdk/src/database/table_name.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/sync/attachment_pipeline.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:frappe_mobile_sdk/src/utils/staged_attachments.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
  late Directory root;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    root = await Directory.systemTemp.createTemp('repo_staged');
    MediaStore.overrideRootForTest(root.path);
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
    await appDb.close();
  });

  Future<String> stage(String name) async {
    final f = File('${root.path}/$name')..writeAsStringSync('PHOTO');
    return MediaStore.stageToOutbox(f);
  }

  group('offline', () {
    late OfflineRepository repo;
    setUp(() async {
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
    });

    test('a staged path swaps to its url only once it has uploaded', () async {
      final path = await stage('a.jpg');
      final uuid = await repo.saveDocument(
        doctype: 'Visit',
        data: {'title': 'A', 'photo': path},
      );
      expect(
        await repo.withUploadedAttachmentUrls({'photo': path}),
        {'photo': path},
        reason: 'not uploaded yet: the path is still the only reference',
      );

      await AttachmentPipeline(
        dao: PendingAttachmentDao(appDb.rawDatabase),
        db: appDb.rawDatabase,
        tableNameFor: (dt) async => normalizeDoctypeTableName(dt),
        uploader:
            (file, {doctype, docname, fileName, isPrivate = true}) async => {
              'file_url': '/private/files/$fileName',
              'name': 'F1',
            },
      ).resolveForTopParent(uuid);

      expect(
        await repo.withUploadedAttachmentUrls({'title': 'A', 'photo': path}),
        {'title': 'A', 'photo': '/private/files/a.jpg'},
      );
    });
  });

  group('online', () {
    late List<http.Request> sent;
    late bool failUpload;
    late bool failCreate;

    OfflineRepository onlineRepo() {
      final mock = MockClient((req) async {
        sent.add(req);
        final path = req.url.path;
        if (path == '/api/method/upload_file') {
          if (failUpload) return http.Response('boom', 500);
          return http.Response(
            jsonEncode({
              'message': {'file_url': '/private/files/a.jpg', 'name': 'F1'},
            }),
            200,
          );
        }
        if (req.method == 'GET') {
          return http.Response(jsonEncode({'data': []}), 200);
        }
        if (failCreate) {
          return http.Response(
            jsonEncode({'exc_type': 'ValidationError'}),
            417,
          );
        }
        return http.Response(
          jsonEncode({
            'data': {'name': 'VISIT-1'},
          }),
          200,
        );
      });
      return OfflineRepository(
        appDb,
        offlineMode: const OfflineMode(enabled: false, isPersisted: true),
        client: FrappeClient('http://localhost', httpClient: mock),
      );
    }

    setUp(() {
      sent = [];
      failUpload = false;
      failCreate = false;
    });

    Map<String, dynamic> createBody() {
      final post = sent.lastWhere(
        (r) => r.method == 'POST' && r.url.path == '/api/resource/Visit',
      );
      return jsonDecode(post.body) as Map<String, dynamic>;
    }

    test(
      'uploads a staged path first and saves its url, never the path',
      () async {
        final path = await stage('a.jpg');
        await onlineRepo().saveDocument(
          doctype: 'Visit',
          data: {'title': 'A', 'photo': path},
        );
        expect(createBody()['photo'], '/private/files/a.jpg');
        expect(
          File(path).existsSync(),
          isFalse,
          reason: 'uploaded and saved: the staged copy is redundant',
        );
      },
    );

    test(
      'a failed upload aborts the save instead of sending the path',
      () async {
        failUpload = true;
        final path = await stage('a.jpg');
        await expectLater(
          onlineRepo().saveDocument(
            doctype: 'Visit',
            data: {'title': 'A', 'photo': path},
          ),
          throwsA(isA<StagedAttachmentUploadException>()),
        );
        expect(sent.where((r) => r.url.path == '/api/resource/Visit'), isEmpty);
        expect(File(path).existsSync(), isTrue);
      },
    );

    test(
      'a failed document save keeps the staged copy for the retry',
      () async {
        failCreate = true;
        final path = await stage('a.jpg');
        await expectLater(
          onlineRepo().saveDocument(
            doctype: 'Visit',
            data: {'title': 'A', 'photo': path},
          ),
          throwsA(anything),
        );
        expect(File(path).existsSync(), isTrue);
      },
    );
  });
}
