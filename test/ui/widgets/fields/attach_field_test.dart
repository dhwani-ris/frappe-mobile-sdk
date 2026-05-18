import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/attach_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
  Future<String?> Function(File)? uploader,
  ValueChanged<dynamic>? onChanged,
  GlobalKey<FormBuilderState>? formKey,
}) async {
  final key = formKey ?? GlobalKey<FormBuilderState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: key,
          child: AttachField(
            field: field,
            value: value,
            uploadFile: uploader,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders "Select file" button when value is null', (
    tester,
  ) async {
    await _pump(
      tester,
      field: DocField(fieldname: 'doc', fieldtype: 'Attach', label: 'Document'),
    );
    expect(find.text('Select file'), findsOneWidget);
  });

  testWidgets('value pre-populates and shows the filename', (tester) async {
    await _pump(
      tester,
      value: '/uploads/report.pdf',
      field: DocField(fieldname: 'doc', fieldtype: 'Attach', label: 'Document'),
    );
    // The button label shows just the basename.
    expect(find.text('report.pdf'), findsOneWidget);
    // The path is rendered below as a smaller helper line.
    expect(find.text('/uploads/report.pdf'), findsOneWidget);
  });

  testWidgets('readOnly disables the picker button', (tester) async {
    await _pump(
      tester,
      value: '/uploads/x.txt',
      field: DocField(
        fieldname: 'doc',
        fieldtype: 'Attach',
        label: 'Document',
        readOnly: true,
      ),
    );
    final btn = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(btn.onPressed, isNull);
  });

  testWidgets('required validator fires when null on submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 'doc',
        fieldtype: 'Attach',
        label: 'Document',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Document is required'), findsOneWidget);
  });

  testWidgets('renders the label above the button', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'doc',
        fieldtype: 'Attach',
        label: 'My Document',
      ),
    );
    expect(find.text('My Document'), findsAtLeastNWidgets(1));
  });
}
