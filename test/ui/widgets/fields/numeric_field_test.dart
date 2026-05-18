import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/numeric_field.dart';

Future<void> _pumpNum(
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
          child: NumericField(field: field, value: value, onChanged: onChanged),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('initial value renders as string', (tester) async {
    await _pumpNum(
      tester,
      value: 42,
      field: DocField(fieldname: 'qty', fieldtype: 'Int', label: 'Qty'),
    );
    expect(find.text('42'), findsOneWidget);
  });

  testWidgets('Int field emits int on change', (tester) async {
    Object? emitted;
    await _pumpNum(
      tester,
      field: DocField(fieldname: 'qty', fieldtype: 'Int', label: 'Qty'),
      onChanged: (v) => emitted = v,
    );
    await tester.enterText(find.byType(TextField), '7');
    expect(emitted, isA<int>());
    expect(emitted, 7);
  });

  testWidgets('Float field emits double on change', (tester) async {
    Object? emitted;
    await _pumpNum(
      tester,
      field: DocField(fieldname: 'amount', fieldtype: 'Float', label: 'Amount'),
      onChanged: (v) => emitted = v,
    );
    await tester.enterText(find.byType(TextField), '12.5');
    expect(emitted, isA<double>());
    expect(emitted, 12.5);
  });

  testWidgets('empty input emits null', (tester) async {
    Object? emitted = 'sentinel';
    await _pumpNum(
      tester,
      value: '5',
      field: DocField(fieldname: 'qty', fieldtype: 'Int', label: 'Qty'),
      onChanged: (v) => emitted = v,
    );
    await tester.enterText(find.byType(TextField), '');
    expect(emitted, isNull);
  });

  testWidgets('Currency field shows ₹ prefix', (tester) async {
    await _pumpNum(
      tester,
      field: DocField(
        fieldname: 'price',
        fieldtype: 'Currency',
        label: 'Price',
      ),
    );
    expect(find.text('₹ '), findsOneWidget);
  });

  testWidgets('Percent field shows % suffix', (tester) async {
    await _pumpNum(
      tester,
      field: DocField(fieldname: 'pct', fieldtype: 'Percent', label: 'Pct'),
    );
    expect(find.text('%'), findsOneWidget);
  });

  testWidgets('Int field disables decimal keyboard', (tester) async {
    await _pumpNum(
      tester,
      field: DocField(fieldname: 'qty', fieldtype: 'Int', label: 'Qty'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(
      tf.keyboardType,
      const TextInputType.numberWithOptions(decimal: false),
    );
  });

  testWidgets('Float field enables decimal keyboard', (tester) async {
    await _pumpNum(
      tester,
      field: DocField(fieldname: 'amount', fieldtype: 'Float', label: 'Amount'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(
      tf.keyboardType,
      const TextInputType.numberWithOptions(decimal: true),
    );
  });

  testWidgets('required validator: empty submit shows "is required"', (
    tester,
  ) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pumpNum(
      tester,
      field: DocField(
        fieldname: 'qty',
        fieldtype: 'Int',
        label: 'Qty',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Qty is required'), findsOneWidget);
  });

  testWidgets('required validator: non-numeric input fails parse', (
    tester,
  ) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pumpNum(
      tester,
      field: DocField(
        fieldname: 'qty',
        fieldtype: 'Int',
        label: 'Qty',
        reqd: true,
      ),
      formKey: formKey,
    );
    await tester.enterText(find.byType(TextField), 'abc');
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Please enter a valid number'), findsOneWidget);
  });

  testWidgets('readOnly disables the field', (tester) async {
    await _pumpNum(
      tester,
      value: 10,
      field: DocField(
        fieldname: 'qty',
        fieldtype: 'Int',
        label: 'Qty',
        readOnly: true,
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.enabled, isFalse);
  });
}
