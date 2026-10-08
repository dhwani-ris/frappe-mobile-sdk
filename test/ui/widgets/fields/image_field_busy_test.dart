import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

/// A picked photo is shrunk (when the host opted in), stored and uploaded
/// before the field shows it. Until that finishes the field shows progress and
/// its buttons are off, so a second tap cannot start a second pick, and a
/// Remove cannot race the pick that is still landing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
  late Directory tmp;
  late File picked;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('image-busy-');
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

  // The pick path mixes real file I/O with the test's fake clock: alternate a
  // real wait (I/O completes) with a pump (microtasks and frames run).
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 15; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
  }

  OutlinedButton button(WidgetTester t, String label) => t.widget(
    find.ancestor(of: find.text(label), matching: find.byType(OutlinedButton)),
  );

  testWidgets('progress shows and the buttons are off until the pick lands', (
    tester,
  ) async {
    final upload = Completer<String?>();
    var uploadCalled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            child: ImageField(
              field: DocField(
                fieldname: 'photo',
                fieldtype: 'Attach Image',
                label: 'Photo',
              ),
              uploadFile: (_) {
                uploadCalled = true;
                return upload.future;
              },
            ),
          ),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(button(tester, 'Gallery').onPressed, isNotNull);

    await tester.tap(find.text('Gallery'));
    // Let the pick, the size check and the durable copy run on real I/O.
    await settle(tester);

    expect(uploadCalled, isTrue, reason: 'the pick reached the upload');
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(button(tester, 'Gallery').onPressed, isNull);
    expect(button(tester, 'Camera').onPressed, isNull);

    upload.complete('/private/files/photo.jpg');
    await settle(tester);

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(button(tester, 'Gallery').onPressed, isNotNull);
    expect(button(tester, 'Camera').onPressed, isNotNull);
  });
}
