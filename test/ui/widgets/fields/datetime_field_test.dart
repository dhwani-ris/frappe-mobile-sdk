import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/datetime_field.dart';

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
          child: DatetimeField(
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
  testWidgets('DateTime value renders yyyy-MM-dd HH:mm:ss', (tester) async {
    await _pump(
      tester,
      value: DateTime(2026, 5, 18, 9, 30, 45),
      field: DocField(fieldname: 'when', fieldtype: 'Datetime', label: 'When'),
    );
    expect(find.text('2026-05-18 09:30:45'), findsOneWidget);
  });

  testWidgets('string value parses via DateTime.tryParse', (tester) async {
    await _pump(
      tester,
      value: '2025-12-31T10:15:00',
      field: DocField(fieldname: 'when', fieldtype: 'Datetime', label: 'When'),
    );
    expect(find.text('2025-12-31 10:15:00'), findsOneWidget);
  });

  testWidgets('unparseable string falls back to hint text', (tester) async {
    await _pump(
      tester,
      value: 'gibberish',
      field: DocField(fieldname: 'when', fieldtype: 'Datetime', label: 'When'),
    );
    expect(find.text('Select date and time'), findsOneWidget);
  });

  testWidgets('placeholder overrides default hint', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'when',
        fieldtype: 'Datetime',
        label: 'When',
        placeholder: 'Pick a moment',
      ),
    );
    expect(find.text('Pick a moment'), findsOneWidget);
  });

  testWidgets('inputType is both', (tester) async {
    await _pump(
      tester,
      field: DocField(fieldname: 'when', fieldtype: 'Datetime', label: 'When'),
    );
    final w = tester.widget<FormBuilderDateTimePicker>(
      find.byType(FormBuilderDateTimePicker),
    );
    expect(w.inputType, InputType.both);
  });

  testWidgets('readOnly disables the picker', (tester) async {
    await _pump(
      tester,
      value: DateTime(2026, 5, 18),
      field: DocField(
        fieldname: 'when',
        fieldtype: 'Datetime',
        label: 'When',
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
        fieldname: 'when',
        fieldtype: 'Datetime',
        label: 'When',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('When is required'), findsOneWidget);
  });
}
