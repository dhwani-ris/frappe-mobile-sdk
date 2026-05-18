import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/date_field.dart';

Future<void> _pumpDate(
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
          child: DateField(field: field, value: value, onChanged: onChanged),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('value=DateTime renders yyyy-MM-dd', (tester) async {
    await _pumpDate(
      tester,
      value: DateTime(2026, 5, 18),
      field: DocField(fieldname: 'dob', fieldtype: 'Date', label: 'DOB'),
    );
    expect(find.text('2026-05-18'), findsOneWidget);
  });

  testWidgets('value=string is parsed via DateTime.tryParse', (tester) async {
    await _pumpDate(
      tester,
      value: '2025-12-31',
      field: DocField(fieldname: 'dob', fieldtype: 'Date', label: 'DOB'),
    );
    expect(find.text('2025-12-31'), findsOneWidget);
  });

  testWidgets('unparseable string yields a blank field', (tester) async {
    await _pumpDate(
      tester,
      value: 'not a date',
      field: DocField(fieldname: 'dob', fieldtype: 'Date', label: 'DOB'),
    );
    expect(
      find.text('Select date'),
      findsOneWidget,
      reason: 'hintText shows when initialValue is null',
    );
  });

  testWidgets('placeholder overrides default hint', (tester) async {
    await _pumpDate(
      tester,
      field: DocField(
        fieldname: 'dob',
        fieldtype: 'Date',
        label: 'DOB',
        placeholder: 'Pick a day',
      ),
    );
    expect(find.text('Pick a day'), findsOneWidget);
  });

  testWidgets('readOnly disables the picker', (tester) async {
    await _pumpDate(
      tester,
      value: DateTime(2026, 1, 1),
      field: DocField(
        fieldname: 'dob',
        fieldtype: 'Date',
        label: 'DOB',
        readOnly: true,
      ),
    );
    final picker = tester.widget<FormBuilderDateTimePicker>(
      find.byType(FormBuilderDateTimePicker),
    );
    expect(picker.enabled, isFalse);
  });

  testWidgets('required validator fires on null submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pumpDate(
      tester,
      field: DocField(
        fieldname: 'dob',
        fieldtype: 'Date',
        label: 'DOB',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('DOB is required'), findsOneWidget);
  });

  testWidgets('hidden field renders nothing', (tester) async {
    await _pumpDate(
      tester,
      field: DocField(
        fieldname: 'secret',
        fieldtype: 'Date',
        label: 'Secret',
        hidden: true,
      ),
    );
    expect(find.byType(FormBuilderDateTimePicker), findsNothing);
  });
}
