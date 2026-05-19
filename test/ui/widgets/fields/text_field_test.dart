import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/text_field.dart';

Future<void> _pumpText(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
  ValueChanged<dynamic>? onChanged,
  GlobalKey<FormBuilderState>? formKey,
}) async {
  final key = formKey ?? GlobalKey<FormBuilderState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: key,
          child: TextFieldWidget(
            field: field,
            value: value,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Text fieldtype renders multi-line input (5 maxLines)', (
    tester,
  ) async {
    await _pumpText(
      tester,
      field: DocField(fieldname: 'notes', fieldtype: 'Text', label: 'Notes'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLines, 5);
  });

  testWidgets('Long Text fieldtype also gets 5 maxLines', (tester) async {
    await _pumpText(
      tester,
      field: DocField(fieldname: 'desc', fieldtype: 'Long Text', label: 'Desc'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLines, 5);
  });

  testWidgets('Small Text gets 3 maxLines', (tester) async {
    await _pumpText(
      tester,
      field: DocField(
        fieldname: 'short',
        fieldtype: 'Small Text',
        label: 'Short',
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLines, 3);
  });

  testWidgets('honors maxLength from field.length', (tester) async {
    await _pumpText(
      tester,
      field: DocField(
        fieldname: 'notes',
        fieldtype: 'Text',
        label: 'Notes',
        length: 200,
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLength, 200);
  });

  testWidgets('onChanged forwards typed text', (tester) async {
    String? emitted;
    await _pumpText(
      tester,
      field: DocField(fieldname: 'notes', fieldtype: 'Text', label: 'Notes'),
      onChanged: (v) => emitted = v as String?,
    );
    await tester.enterText(find.byType(TextField), 'hello there');
    expect(emitted, 'hello there');
  });

  testWidgets('required validator fires on empty submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pumpText(
      tester,
      field: DocField(
        fieldname: 'notes',
        fieldtype: 'Text',
        label: 'Notes',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Notes is required'), findsOneWidget);
  });

  testWidgets('readOnly disables editing', (tester) async {
    await _pumpText(
      tester,
      value: 'fixed',
      field: DocField(
        fieldname: 'notes',
        fieldtype: 'Text',
        label: 'Notes',
        readOnly: true,
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.enabled, isFalse);
  });
}
