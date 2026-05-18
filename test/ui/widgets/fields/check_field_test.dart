import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/check_field.dart';

Future<void> _pumpCheck(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
  ValueChanged<dynamic>? onChanged,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          child: CheckField(
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
  testWidgets('value=true renders the switch as on', (tester) async {
    await _pumpCheck(
      tester,
      value: true,
      field: DocField(
        fieldname: 'is_active',
        fieldtype: 'Check',
        label: 'Active',
      ),
    );
    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, isTrue);
  });

  testWidgets('value=1 (int) renders the switch as on', (tester) async {
    await _pumpCheck(
      tester,
      value: 1,
      field: DocField(fieldname: 'a', fieldtype: 'Check', label: 'A'),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('value="1" (string) renders the switch as on', (tester) async {
    await _pumpCheck(
      tester,
      value: '1',
      field: DocField(fieldname: 'a', fieldtype: 'Check', label: 'A'),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('value="true" (string, case-insensitive) renders as on', (
    tester,
  ) async {
    await _pumpCheck(
      tester,
      value: 'True',
      field: DocField(fieldname: 'a', fieldtype: 'Check', label: 'A'),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('defaultValue applies when value is null', (tester) async {
    await _pumpCheck(
      tester,
      field: DocField(
        fieldname: 'a',
        fieldtype: 'Check',
        label: 'A',
        defaultValue: '1',
      ),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('null value with no default renders off', (tester) async {
    await _pumpCheck(
      tester,
      field: DocField(fieldname: 'a', fieldtype: 'Check', label: 'A'),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('tap emits 1 when off→on; 0 when on→off', (tester) async {
    final emitted = <int>[];
    await _pumpCheck(
      tester,
      field: DocField(fieldname: 'a', fieldtype: 'Check', label: 'A'),
      onChanged: (v) => emitted.add(v as int),
    );
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(emitted, [1]);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(emitted, [1, 0]);
  });

  testWidgets('readOnly disables the switch', (tester) async {
    await _pumpCheck(
      tester,
      value: false,
      field: DocField(
        fieldname: 'a',
        fieldtype: 'Check',
        label: 'A',
        readOnly: true,
      ),
    );
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
  });

  testWidgets('title uses placeholder when provided, else label', (
    tester,
  ) async {
    await _pumpCheck(
      tester,
      field: DocField(
        fieldname: 'a',
        fieldtype: 'Check',
        label: 'A label',
        placeholder: 'Custom title',
      ),
    );
    expect(find.text('Custom title'), findsWidgets);
  });
}
