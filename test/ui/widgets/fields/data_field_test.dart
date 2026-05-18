import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/data_field.dart';

Future<void> _pumpDataField(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
  ValueChanged<dynamic>? onChanged,
  bool enabled = true,
  GlobalKey<FormBuilderState>? formKey,
}) async {
  final key = formKey ?? GlobalKey<FormBuilderState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: key,
          child: DataField(
            field: field,
            value: value,
            onChanged: onChanged,
            enabled: enabled,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders label with asterisk when field is required', (
    tester,
  ) async {
    await _pumpDataField(
      tester,
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Data',
        label: 'Customer Name',
        reqd: true,
      ),
    );
    expect(find.text('Customer Name'), findsOneWidget);
    expect(find.text('*'), findsOneWidget);
  });

  testWidgets('hidden field renders nothing', (tester) async {
    await _pumpDataField(
      tester,
      field: DocField(
        fieldname: 'secret',
        fieldtype: 'Data',
        label: 'Secret',
        hidden: true,
      ),
    );
    expect(find.byType(FormBuilderTextField), findsNothing);
    expect(find.text('Secret'), findsNothing);
  });

  testWidgets('initialValue defaults to defaultValue when no value provided', (
    tester,
  ) async {
    await _pumpDataField(
      tester,
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Data',
        label: 'Name',
        defaultValue: 'Acme',
      ),
    );
    expect(find.text('Acme'), findsOneWidget);
  });

  testWidgets('value param takes precedence over defaultValue', (tester) async {
    await _pumpDataField(
      tester,
      value: 'Beta',
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Data',
        label: 'Name',
        defaultValue: 'Acme',
      ),
    );
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('onChanged fires with the typed value', (tester) async {
    String? lastValue;
    await _pumpDataField(
      tester,
      field: DocField(fieldname: 'name', fieldtype: 'Data', label: 'Name'),
      onChanged: (v) => lastValue = v as String?,
    );
    await tester.enterText(find.byType(TextField), 'Hello');
    expect(lastValue, 'Hello');
  });

  testWidgets('readOnly field is greyed and not editable', (tester) async {
    String? lastValue;
    await _pumpDataField(
      tester,
      value: 'fixed',
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Data',
        label: 'Name',
        readOnly: true,
      ),
      onChanged: (v) => lastValue = v as String?,
    );
    // Attempt to enter text — should not produce an onChanged because
    // the underlying TextField is disabled.
    expect(find.text('fixed'), findsOneWidget);
    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.enabled, isFalse);
    // No edit fired:
    expect(lastValue, isNull);
  });

  testWidgets('required validator fires on empty submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pumpDataField(
      tester,
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Data',
        label: 'Name',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Name is required'), findsOneWidget);
  });

  testWidgets('phone field auto-prepends + when typing digits', (tester) async {
    String? lastValue;
    await _pumpDataField(
      tester,
      field: DocField(fieldname: 'phone', fieldtype: 'Phone', label: 'Phone'),
      onChanged: (v) => lastValue = v as String?,
    );
    await tester.enterText(find.byType(TextField), '919999999999');
    expect(lastValue, '+919999999999');
  });

  testWidgets('phone field validator rejects values without +', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pumpDataField(
      tester,
      field: DocField(
        fieldname: 'phone',
        fieldtype: 'Phone',
        label: 'Phone',
        reqd: true,
      ),
      formKey: formKey,
    );
    // Auto-prepend kicks in via onChanged; bypass it by writing a non-numeric
    // value that the regex catches.
    await tester.enterText(find.byType(TextField), '++abc');
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    // Either the "must start with +" or the "valid phone number" message.
    final errorTexts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .toList();
    expect(
      errorTexts.any(
        (s) =>
            s.contains('Please enter a valid phone number with country code'),
      ),
      isTrue,
    );
  });

  testWidgets('phone field hint defaults to placeholder when set', (
    tester,
  ) async {
    await _pumpDataField(
      tester,
      field: DocField(
        fieldname: 'phone',
        fieldtype: 'Phone',
        label: 'Phone',
        placeholder: 'Your number',
      ),
    );
    expect(find.text('Your number'), findsOneWidget);
  });

  testWidgets(
    'phone field hint defaults to country-code prompt when no placeholder',
    (tester) async {
      await _pumpDataField(
        tester,
        field: DocField(fieldname: 'phone', fieldtype: 'Phone', label: 'Phone'),
      );
      expect(find.text('e.g., +91XXXXXXXXXX'), findsOneWidget);
    },
  );
}
