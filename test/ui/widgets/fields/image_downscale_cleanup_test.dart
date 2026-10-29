import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:image/image.dart' as img;
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

/// The opt-in photo shrink (ImageUploadSettings.captureLimits) writes the
/// smaller photo into a new `downscaled_*` folder next to the picked file.
/// The image field copies it into the attachment store before it uploads or
/// keeps it, so the folder is dead once the pick is resolved, but nothing
/// removed it: every shrunk photo left a copy behind.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  late Directory tmp;
  late Directory pickDir;
  late File picked;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('downscale-cleanup-');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    // Where the platform picker leaves its file.
    pickDir = await Directory('${tmp.path}/picker').create();
    final photo = img.Image(width: 256, height: 192);
    for (final px in photo) {
      px
        ..r = px.x
        ..g = px.y
        ..b = (px.x + px.y) % 256;
    }
    picked = File('${pickDir.path}/photo.jpg')
      ..writeAsBytesSync(img.encodeJpg(photo, quality: 95));
    // Shrinks a 256 px photo by 4, the way 1920 shrinks a 7680 px one.
    ImageUploadSettings.captureLimits = const ImageCaptureLimits(
      targetLongEdge: 64,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, (call) async {
          if (call.method == 'pickImage') return picked.path;
          return null;
        });
  });

  tearDown(() async {
    ImageUploadSettings.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pickerChannel, null);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> settleUntil(
    WidgetTester t,
    bool Function() done, {
    int seconds = 20,
  }) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(end)) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  List<String> downscaledFolders() => pickDir
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path.split(Platform.pathSeparator).last)
      .where((n) => n.startsWith('downscaled_'))
      .toList();

  final meta = DocTypeMeta(
    name: 'TestDoctype',
    fields: <DocField>[
      DocField(fieldname: 'photo', fieldtype: 'Attach Image', label: 'Photo'),
    ],
  );

  /// Picks the photo in a form and returns the field's value once it lands.
  Future<String> pick(
    WidgetTester tester, {
    Future<String?> Function(File file)? uploadFile,
  }) async {
    String? value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            uploadFile: uploadFile,
            onFormDataChanged: (d) => value = d['photo'] as String?,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Gallery'));
    await settleUntil(
      tester,
      () =>
          value != null &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    expect(value, isNotNull, reason: 'the photo landed in the field');
    return value!;
  }

  testWidgets('an uploaded photo leaves no downscaled copy behind', (
    tester,
  ) async {
    final uploaded = <int>[];
    final url = await pick(
      tester,
      uploadFile: (file) async {
        // The upload reads the shrunk photo, from the attachment store.
        expect(file.path, isNot(contains('downscaled_')));
        uploaded.add(file.lengthSync());
        return '/private/files/photo.jpg';
      },
    );
    expect(url, '/private/files/photo.jpg');
    expect(uploaded.single, lessThan(picked.lengthSync()), reason: 'shrunk');
    expect(downscaledFolders(), isEmpty);
    expect(
      picked.existsSync(),
      isTrue,
      reason: "the picker's file is not ours",
    );
  });

  testWidgets('a photo kept on the device keeps its stored copy', (
    tester,
  ) async {
    final stored = await pick(tester);
    expect(stored, isNot(contains('downscaled_')));
    expect(File(stored).existsSync(), isTrue, reason: "the field's value");
    expect(File(stored).lengthSync(), lessThan(picked.lengthSync()));
    expect(downscaledFolders(), isEmpty);
  });

  testWidgets('a failed upload keeps the stored copy, not the downscaled one', (
    tester,
  ) async {
    final stored = await pick(
      tester,
      uploadFile: (_) async => throw const SocketException('network down'),
    );
    expect(stored, isNot(contains('downscaled_')));
    expect(File(stored).existsSync(), isTrue, reason: 'queued at save');
    expect(downscaledFolders(), isEmpty);
  });

  testWidgets('a photo that is not shrunk is left alone', (tester) async {
    ImageUploadSettings.captureLimits = const ImageCaptureLimits(
      targetLongEdge: 4096,
    );
    final stored = await pick(tester);
    expect(File(stored).lengthSync(), picked.lengthSync());
    expect(picked.existsSync(), isTrue);
    expect(downscaledFolders(), isEmpty);
  });
}
