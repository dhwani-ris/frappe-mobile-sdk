import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/read_only_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          child: ReadOnlyField(field: field, value: value),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders value as display text', (tester) async {
    await _pump(
      tester,
      value: 'Customer Acme',
      field: DocField(fieldname: 'name', fieldtype: 'Read Only', label: 'Name'),
    );
    expect(find.text('Customer Acme'), findsOneWidget);
  });

  testWidgets('falls back to defaultValue when value is null', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Read Only',
        label: 'Name',
        defaultValue: 'fallback',
      ),
    );
    expect(find.text('fallback'), findsOneWidget);
  });

  testWidgets('always disabled regardless of enabled / readOnly settings', (
    tester,
  ) async {
    await _pump(
      tester,
      value: 'x',
      field: DocField(fieldname: 'name', fieldtype: 'Read Only', label: 'Name'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.enabled, isFalse);
    expect(tf.readOnly, isTrue);
  });

  testWidgets('description appears as helperText', (tester) async {
    await _pump(
      tester,
      value: 'x',
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Read Only',
        label: 'Name',
        description: 'Cannot be changed',
      ),
    );
    expect(find.text('Cannot be changed'), findsWidgets);
  });
}
