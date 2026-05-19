import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/duration_field.dart';

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
          child: DurationField(
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
  testWidgets('int seconds renders MM:SS when <1h', (tester) async {
    await _pump(
      tester,
      value: 125,
      field: DocField(fieldname: 'd', fieldtype: 'Duration', label: 'D'),
    );
    expect(find.text('02:05'), findsOneWidget);
  });

  testWidgets('int seconds renders HH:MM:SS when ≥1h', (tester) async {
    await _pump(
      tester,
      value: 3661,
      field: DocField(fieldname: 'd', fieldtype: 'Duration', label: 'D'),
    );
    expect(find.text('01:01:01'), findsOneWidget);
  });

  testWidgets('string HH:MM:SS parses', (tester) async {
    await _pump(
      tester,
      value: '01:30:00',
      field: DocField(fieldname: 'd', fieldtype: 'Duration', label: 'D'),
    );
    expect(find.text('01:30:00'), findsOneWidget);
  });

  testWidgets('string MM:SS parses and re-renders', (tester) async {
    await _pump(
      tester,
      value: '02:05',
      field: DocField(fieldname: 'd', fieldtype: 'Duration', label: 'D'),
    );
    expect(find.text('02:05'), findsOneWidget);
  });

  testWidgets('typed HH:MM:SS emits parsed seconds via onChanged', (
    tester,
  ) async {
    int? emitted;
    await _pump(
      tester,
      field: DocField(fieldname: 'd', fieldtype: 'Duration', label: 'D'),
      onChanged: (v) => emitted = v as int?,
    );
    await tester.enterText(find.byType(TextField), '00:02:30');
    expect(emitted, 150);
  });

  testWidgets('plain integer string is parsed as seconds', (tester) async {
    int? emitted;
    await _pump(
      tester,
      field: DocField(fieldname: 'd', fieldtype: 'Duration', label: 'D'),
      onChanged: (v) => emitted = v as int?,
    );
    await tester.enterText(find.byType(TextField), '300');
    expect(emitted, 300);
  });

  testWidgets('invalid format yields validator error on submit', (
    tester,
  ) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(fieldname: 'd', fieldtype: 'Duration', label: 'D'),
      formKey: formKey,
    );
    await tester.enterText(find.byType(TextField), 'oops');
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Invalid duration format'), findsOneWidget);
  });

  testWidgets('required validator catches empty submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 'd',
        fieldtype: 'Duration',
        label: 'D',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('D is required'), findsOneWidget);
  });
}
