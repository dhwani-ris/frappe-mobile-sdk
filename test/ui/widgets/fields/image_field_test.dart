// Covers ImageField's URL classification, display rendering, and read-only
// behaviour. The actual ImagePicker flow goes through a platform channel; that
// integration is covered by on-device suites.
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
  String? fileUrlBase,
  Map<String, String>? imageHeaders,
  bool enabled = true,
  GlobalKey<FormBuilderState>? formKey,
}) async {
  final key = formKey ?? GlobalKey<FormBuilderState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: key,
          child: ImageField(
            field: field,
            value: value,
            enabled: enabled,
            fileUrlBase: fileUrlBase,
            imageHeaders: imageHeaders,
          ),
        ),
      ),
    ),
  );
}

void main() {
  final field = DocField(
    fieldname: 'avatar',
    fieldtype: 'Image',
    label: 'Avatar',
  );

  testWidgets('renders Gallery + Camera buttons when enabled', (tester) async {
    await _pump(tester, field: field);
    expect(find.text('Gallery'), findsOneWidget);
    expect(find.text('Camera'), findsOneWidget);
  });

  testWidgets('readOnly disables both pick buttons', (tester) async {
    final readField = DocField(
      fieldname: 'avatar',
      fieldtype: 'Image',
      label: 'Avatar',
      readOnly: true,
    );
    await _pump(tester, field: readField);
    final buttons = tester
        .widgetList<OutlinedButton>(find.byType(OutlinedButton))
        .toList();
    expect(buttons, hasLength(2));
    expect(buttons.every((b) => b.onPressed == null), isTrue);
  });

  testWidgets('http URL renders Image.network', (tester) async {
    await _pump(tester, field: field, value: 'https://example.com/img.png');
    expect(find.byType(Image), findsOneWidget);
    // No /api/method/frappe.handler.download_file rewrite for http URLs.
  });

  testWidgets('/files/ path with fileUrlBase rewrites to download_file API', (
    tester,
  ) async {
    await _pump(
      tester,
      field: field,
      value: '/files/avatar.png',
      fileUrlBase: 'http://example.com/',
    );
    final img = tester.widget<Image>(find.byType(Image));
    final url = (img.image as NetworkImage).url;
    expect(
      url,
      'http://example.com/api/method/frappe.handler.download_file?file_url=%2Ffiles%2Favatar.png',
    );
  });

  testWidgets(
    '/private/files/ path with fileUrlBase rewrites to download_file API',
    (tester) async {
      await _pump(
        tester,
        field: field,
        value: '/private/files/secret.png',
        fileUrlBase: 'http://example.com',
      );
      final img = tester.widget<Image>(find.byType(Image));
      final url = (img.image as NetworkImage).url;
      expect(
        url,
        'http://example.com/api/method/frappe.handler.download_file?file_url=%2Fprivate%2Ffiles%2Fsecret.png',
      );
    },
  );

  testWidgets('local absolute path falls back to broken-image placeholder', (
    tester,
  ) async {
    // _isServerUrl returns false for /home/ paths → Image.file is used.
    // The file doesn't exist, so errorBuilder fires (broken_image icon).
    await _pump(tester, field: field, value: '/home/local/file.png');
    // Image.file is added to the tree; the actual error happens async.
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('required validator fires on null submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 'avatar',
        fieldtype: 'Image',
        label: 'Avatar',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Avatar is required'), findsOneWidget);
  });

  testWidgets('imageHeaders are passed to Image.network for private files', (
    tester,
  ) async {
    await _pump(
      tester,
      field: field,
      value: '/private/files/x.png',
      fileUrlBase: 'http://example.com',
      imageHeaders: {'Authorization': 'Bearer tok'},
    );
    final img = tester.widget<Image>(find.byType(Image));
    final headers = (img.image as NetworkImage).headers;
    expect(headers, {'Authorization': 'Bearer tok'});
  });
}
