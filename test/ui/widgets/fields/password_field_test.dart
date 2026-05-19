import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/password_field.dart';

Future<void> _pump(
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
          child: PasswordField(
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
  testWidgets('text is obscured (obscureText=true)', (tester) async {
    await _pump(
      tester,
      value: 'secret',
      field: DocField(fieldname: 'pw', fieldtype: 'Password', label: 'PW'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.obscureText, isTrue);
  });

  testWidgets('default hint reads "Enter password"', (tester) async {
    await _pump(
      tester,
      field: DocField(fieldname: 'pw', fieldtype: 'Password', label: 'PW'),
    );
    expect(find.text('Enter password'), findsOneWidget);
  });

  testWidgets('onChanged emits the typed value (unobscured payload)', (
    tester,
  ) async {
    String? emitted;
    await _pump(
      tester,
      field: DocField(fieldname: 'pw', fieldtype: 'Password', label: 'PW'),
      onChanged: (v) => emitted = v as String?,
    );
    await tester.enterText(find.byType(TextField), 'hunter2');
    expect(emitted, 'hunter2');
  });

  testWidgets('required validator fires on empty submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 'pw',
        fieldtype: 'Password',
        label: 'PW',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('PW is required'), findsOneWidget);
  });

  testWidgets('readOnly disables the field', (tester) async {
    await _pump(
      tester,
      value: 'secret',
      field: DocField(
        fieldname: 'pw',
        fieldtype: 'Password',
        label: 'PW',
        readOnly: true,
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.enabled, isFalse);
  });
}
