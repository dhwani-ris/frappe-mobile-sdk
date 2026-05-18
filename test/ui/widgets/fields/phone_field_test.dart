import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/phone_field.dart';

Future<void> _pumpPhone(
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
          child: PhoneField(field: field, value: value, onChanged: onChanged),
        ),
      ),
    ),
  );
}

void main() {
  group('numberFromStored', () {
    test('strips +91 prefix', () {
      expect(PhoneField.numberFromStored('+919876543210'), '9876543210');
    });
    test('returns empty for empty / null / "+91" alone', () {
      expect(PhoneField.numberFromStored(null), '');
      expect(PhoneField.numberFromStored(''), '');
      expect(PhoneField.numberFromStored('+91'), '');
      expect(PhoneField.numberFromStored('91'), '');
    });
    test('returns digits when prefix is absent', () {
      expect(PhoneField.numberFromStored('98765-43210'), '9876543210');
    });
  });

  group('toStored', () {
    test('prepends +91 to a 10-digit number', () {
      expect(PhoneField.toStored('9876543210'), '+919876543210');
    });
    test('strips non-digits before prepending +91', () {
      expect(PhoneField.toStored('98-76 54 32 10'), '+919876543210');
    });
    test('empty input returns empty (not "+91")', () {
      expect(PhoneField.toStored(''), '');
    });
  });

  group('widget', () {
    testWidgets('initial value strips +91 and shows only the number', (
      tester,
    ) async {
      await _pumpPhone(
        tester,
        value: '+919876543210',
        field: DocField(fieldname: 'phone', fieldtype: 'Phone', label: 'Phone'),
      );
      expect(find.text('9876543210'), findsOneWidget);
    });

    testWidgets('onChanged stores back as +91-prefixed value', (tester) async {
      String? emitted;
      await _pumpPhone(
        tester,
        field: DocField(fieldname: 'phone', fieldtype: 'Phone', label: 'Phone'),
        onChanged: (v) => emitted = v as String?,
      );
      await tester.enterText(find.byType(TextField), '9876543210');
      expect(emitted, '+919876543210');
    });

    testWidgets('clearing the field emits null', (tester) async {
      Object? emitted = 'sentinel';
      await _pumpPhone(
        tester,
        value: '+919876543210',
        field: DocField(fieldname: 'phone', fieldtype: 'Phone', label: 'Phone'),
        onChanged: (v) => emitted = v,
      );
      await tester.enterText(find.byType(TextField), '');
      expect(emitted, isNull);
    });

    testWidgets('required validator fails on empty submit', (tester) async {
      final formKey = GlobalKey<FormBuilderState>();
      await _pumpPhone(
        tester,
        field: DocField(
          fieldname: 'phone',
          fieldtype: 'Phone',
          label: 'Phone',
          reqd: true,
        ),
        formKey: formKey,
      );
      formKey.currentState!.saveAndValidate();
      await tester.pump();
      expect(find.text('Phone is required'), findsOneWidget);
    });

    testWidgets('required validator fails on <10 digits', (tester) async {
      final formKey = GlobalKey<FormBuilderState>();
      await _pumpPhone(
        tester,
        field: DocField(
          fieldname: 'phone',
          fieldtype: 'Phone',
          label: 'Phone',
          reqd: true,
        ),
        formKey: formKey,
      );
      await tester.enterText(find.byType(TextField), '12345');
      formKey.currentState!.saveAndValidate();
      await tester.pump();
      expect(
        find.text('Please enter a valid 10-digit mobile number'),
        findsOneWidget,
      );
    });

    testWidgets('optional field validates non-empty short input', (
      tester,
    ) async {
      final formKey = GlobalKey<FormBuilderState>();
      await _pumpPhone(
        tester,
        field: DocField(fieldname: 'phone', fieldtype: 'Phone', label: 'Phone'),
        formKey: formKey,
      );
      await tester.enterText(find.byType(TextField), '12');
      formKey.currentState!.saveAndValidate();
      await tester.pump();
      expect(
        find.text('Please enter a valid 10-digit mobile number'),
        findsOneWidget,
      );
    });

    testWidgets('maxLength defaults to 10 when field.length is null', (
      tester,
    ) async {
      await _pumpPhone(
        tester,
        field: DocField(fieldname: 'phone', fieldtype: 'Phone', label: 'Phone'),
      );
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.maxLength, 10);
    });
  });
}
