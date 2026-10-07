// Online (server-first) FormScreen with a photo whose inline upload failed at
// pick time, so the field holds the staged path. The save must upload it and
// POST the url — never the device path — and a second save from the same open
// screen (the user re-submits) must reuse that url instead of re-uploading a
// staged copy that was already cleaned up.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  fields: [
    DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title'),
    DocField(fieldname: 'photo', fieldtype: 'Attach Image', label: 'Photo'),
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;
  late Directory root;
  late List<http.Request> sent;
  late FrappeClient api;
  late OfflineRepository repo;
  void Function()? submit;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
    root = await Directory.systemTemp.createTemp('fs_online_staged');
    MediaStore.overrideRootForTest(root.path);
    sent = [];
    api = FrappeClient(
      'http://localhost',
      httpClient: MockClient((req) async {
        sent.add(req);
        if (req.url.path == '/api/method/upload_file') {
          return http.Response(
            jsonEncode({
              'message': {'file_url': '/private/files/site.jpg', 'name': 'F1'},
            }),
            200,
          );
        }
        if (req.method == 'POST' && req.url.path == '/api/resource/Visit') {
          return http.Response(
            jsonEncode({
              'data': {'name': 'VISIT-${sent.length}'},
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'data': [], 'message': []}), 200);
      }),
    );
    repo = OfflineRepository(
      appDb,
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      client: api,
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

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    if (await root.exists()) await root.delete(recursive: true);
    await appDb.close();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> save(WidgetTester tester) async {
    expect(submit, isNotNull, reason: 'form never registered its submit');
    await tester.runAsync(() async {
      submit!();
      await tester.pump();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await settle(tester);
  }

  List<Map<String, dynamic>> creates() => [
    for (final r in sent)
      if (r.method == 'POST' && r.url.path == '/api/resource/Visit')
        jsonDecode(r.body) as Map<String, dynamic>,
  ];

  testWidgets('posts the uploaded url, and reuses it on a re-submit', (
    tester,
  ) async {
    final staged = (await tester.runAsync(() async {
      final f = File('${root.path}/site.jpg')..writeAsStringSync('PHOTO');
      return MediaStore.stageToOutbox(f);
    }))!;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormScreen(
            meta: _meta(),
            repository: repo,
            api: api,
            initialData: {'title': 'Site', 'photo': staged},
            registerSubmit: (trigger) => submit = trigger,
          ),
        ),
      ),
    );
    await settle(tester);

    await save(tester);
    expect(creates(), hasLength(1));
    expect(creates().single['photo'], '/private/files/site.jpg');
    expect(
      File(staged).existsSync(),
      isFalse,
      reason: 'saved, so the staged copy is cleaned up',
    );

    await save(tester);
    expect(creates(), hasLength(2));
    expect(creates().last['photo'], '/private/files/site.jpg');
    expect(
      sent.where((r) => r.url.path == '/api/method/upload_file'),
      hasLength(1),
    );
  });
}
