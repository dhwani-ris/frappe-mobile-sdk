import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/time_field.dart';

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
          child: TimeField(field: field, value: value, onChanged: onChanged),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('TimeOfDay value renders HH:mm:ss', (tester) async {
    await _pump(
      tester,
      value: const TimeOfDay(hour: 14, minute: 30),
      field: DocField(fieldname: 't', fieldtype: 'Time', label: 'T'),
    );
    expect(find.text('14:30:00'), findsOneWidget);
  });

  testWidgets('string value with HH:mm parses', (tester) async {
    await _pump(
      tester,
      value: '09:45',
      field: DocField(fieldname: 't', fieldtype: 'Time', label: 'T'),
    );
    expect(find.text('09:45:00'), findsOneWidget);
  });

  testWidgets('non-time string yields hint text', (tester) async {
    await _pump(
      tester,
      value: 'not-a-time',
      field: DocField(fieldname: 't', fieldtype: 'Time', label: 'T'),
    );
    expect(find.text('Select time'), findsOneWidget);
  });

  testWidgets('inputType is time', (tester) async {
    await _pump(
      tester,
      field: DocField(fieldname: 't', fieldtype: 'Time', label: 'T'),
    );
    final w = tester.widget<FormBuilderDateTimePicker>(
      find.byType(FormBuilderDateTimePicker),
    );
    expect(w.inputType, InputType.time);
  });

  testWidgets('readOnly disables', (tester) async {
    await _pump(
      tester,
      value: '12:00',
      field: DocField(
        fieldname: 't',
        fieldtype: 'Time',
        label: 'T',
        readOnly: true,
      ),
    );
    final w = tester.widget<FormBuilderDateTimePicker>(
      find.byType(FormBuilderDateTimePicker),
    );
    expect(w.enabled, isFalse);
  });

  testWidgets('required validator fires on null submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 't',
        fieldtype: 'Time',
        label: 'T',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('T is required'), findsOneWidget);
  });
}
