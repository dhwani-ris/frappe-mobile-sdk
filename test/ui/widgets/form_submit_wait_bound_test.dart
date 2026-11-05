import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/pending_field_work.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

/// Save waits for a photo that is still uploading, so the record keeps it.
/// That wait had no upper bound, and the Save button showed nothing while it
/// waited: a second tap was silently ignored. The wait now ends after
/// [kFieldWorkSaveTimeout] and the form saves as the fields stand, and the
/// SDK's own Save buttons show that they are waiting.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  late Directory tmp;
  late File picked;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('form-wait-bound-');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    picked = File('${tmp.path}/photo.jpg')..writeAsBytesSync([1, 2, 3, 4]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (call) async {
          if (call.method == 'pickImage') return picked.path;
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settleUntil(
    WidgetTester t,
    bool Function() done, {
    int seconds = 15,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(end)) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> settle(WidgetTester t, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  group('PendingFieldWork.whenIdle(timeout:)', () {
    test('true once the work finishes in time', () async {
      final work = PendingFieldWork();
      final gate = Completer<void>();
      work.track(gate.future);
      final idle = work.whenIdle(timeout: const Duration(seconds: 5));
      gate.complete();
      expect(await idle, isTrue);
    });

    test('false when the work is still running at the bound', () async {
      final work = PendingFieldWork();
      work.track(Completer<void>().future);
      expect(
        await work.whenIdle(timeout: const Duration(milliseconds: 20)),
        isFalse,
      );
      expect(work.isBusy, isTrue, reason: 'the work itself is not cancelled');
    });

    test('with nothing tracked it is idle at once', () async {
      expect(await PendingFieldWork().whenIdle(timeout: Duration.zero), isTrue);
    });
  });

  test('the bound outlasts the SDK upload timeout', () {
    // RestHelper gives an upload 5 minutes, after which the photo field keeps
    // the photo as a local file and its work ends. The save must not give up
    // first, or it would save the record without the photo.
    expect(kFieldWorkSaveTimeout, greaterThan(const Duration(minutes: 5)));
  });

  final meta = DocTypeMeta(
    name: 'TestDoctype',
    fields: <DocField>[
      DocField(fieldname: 'photo', fieldtype: 'Attach Image', label: 'Photo'),
      DocField(fieldname: 'note', fieldtype: 'Data', label: 'Note'),
    ],
  );

  for (final mode in FormBuilderMode.values) {
    testWidgets('${mode.name}: an upload that never ends stops blocking Save '
        'at the bound', (tester) async {
      final submits = <Map<String, dynamic>>[];
      var started = false;
      late void Function() submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta,
              mode: mode,
              initialData: const {'note': 'kept'},
              uploadFile: (_) {
                started = true;
                return Completer<String?>().future;
              },
              onSubmit: submits.add,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Gallery'));
      await settleUntil(tester, () => started);
      expect(started, isTrue, reason: 'the pick reached the upload');

      submit();
      await tester.pump(kFieldWorkSaveTimeout - const Duration(seconds: 1));
      expect(submits, isEmpty, reason: 'still inside the bound');

      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(submits, hasLength(1), reason: 'saved as the fields stand');
      expect(submits.single['note'], 'kept');
      expect(submits.single['photo'], anyOf(isNull, isEmpty));

      // A Save pressed after the bound is not swallowed by the earlier wait.
      submit();
      await tester.pump(kFieldWorkSaveTimeout + const Duration(seconds: 1));
      await tester.pump();
      expect(submits, hasLength(2));
    });
  }

  testWidgets('the child-table row Save shows that it waits for the photo', (
    tester,
  ) async {
    final upload = Completer<String?>();
    var started = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: DocTypeMeta(
              name: 'Parent',
              fields: <DocField>[
                DocField(
                  fieldname: 'rows',
                  fieldtype: 'Table',
                  label: 'Rows',
                  options: 'RowDoctype',
                ),
              ],
            ),
            getMeta: (_) async => DocTypeMeta(
              name: 'RowDoctype',
              isTable: true,
              fields: <DocField>[
                DocField(
                  fieldname: 'picture',
                  fieldtype: 'Attach Image',
                  label: 'Picture',
                ),
              ],
            ),
            uploadFile: (_) {
              started = true;
              return upload.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Row'));
    await settle(tester);
    await tester.tap(find.text('Gallery'));
    await settleUntil(tester, () => started);

    FilledButton sheetSave() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Save'),
        matching: find.bySubtype<FilledButton>(),
      ),
    );
    expect(sheetSave().onPressed, isNotNull);

    await tester.tap(find.text('Save'));
    await settle(tester, rounds: 3);
    expect(sheetSave().onPressed, isNull, reason: 'off while it waits');
    expect(
      find.descendant(
        of: find.bySubtype<FilledButton>(),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    upload.complete('/private/files/row.jpg');
    await settleUntil(tester, () => find.text('Save').evaluate().isEmpty);
    expect(find.text('Save'), findsNothing, reason: 'row added, sheet closed');
  });

  testWidgets('FormScreen Save shows that it waits for the photo', (
    tester,
  ) async {
    final appDb = (await tester.runAsync(AppDatabase.inMemoryDatabase))!;
    final repo = OfflineRepository(
      appDb,
      localWriter: LocalWriter(appDb.rawDatabase, (_) async => meta),
      // Online-first, so the pick uploads inline.
      offlineMode: const OfflineMode(enabled: false, isPersisted: true),
      metaFetcher: (_) async => meta,
    );
    final upload = Completer<void>();
    var started = false;
    final api = FrappeClient(
      'https://example.test',
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('upload_file')) {
          started = true;
          await upload.future;
          return http.Response(
            jsonEncode({
              'message': {'file_url': '/private/files/photo.jpg'},
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'message': <String, Object?>{}}), 200);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: FormScreen(meta: meta, repository: repo, api: api),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Gallery'));
    await settleUntil(tester, () => started);
    expect(started, isTrue);

    TextButton save() =>
        tester.widget<TextButton>(find.byKey(const Key('form_save_button')));
    expect(save().onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('form_save_button')));
    await settle(tester, rounds: 3);
    expect(save().onPressed, isNull, reason: 'off while it waits');
    expect(
      find.descendant(
        of: find.byKey(const Key('form_save_button')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    upload.complete();
    await settleUntil(
      tester,
      () => find
          .descendant(
            of: find.byKey(const Key('form_save_button')),
            matching: find.byType(CircularProgressIndicator),
          )
          .evaluate()
          .isEmpty,
    );
    await settle(tester);
    // Snackbars and route animations from the save.
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(() => appDb.close());
  });
}
