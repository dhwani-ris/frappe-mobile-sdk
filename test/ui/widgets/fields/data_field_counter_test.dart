// A `Data` field is capped at Frappe's implicit varchar(140) so free text
// can't overflow and fail server-side with a 417 only at sync time. The cap
// itself is correct — but it used to be SILENT (buildCounter always returned
// null), so typing simply stopped registering with no counter and no message.
// The counter must appear as the user approaches the cap and stay hidden
// otherwise, so the common case still matches the web UI's clean look.

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/data_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  bool capLength = true,
  dynamic value,
  bool enabled = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: GlobalKey<FormBuilderState>(),
          child: DataField(
            field: field,
            value: value,
            enabled: enabled,
            capLength: capLength,
          ),
        ),
      ),
    ),
  );
}

DocField _dataField({int? length}) => DocField(
  fieldname: 'name',
  fieldtype: 'Data',
  label: 'Name',
  length: length,
);

/// Any counter the field renders, e.g. "125/140". Empty when hidden.
Iterable<String> _counters(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => RegExp(r'^\d+/\d+$').hasMatch(s));

void main() {
  testWidgets('counter is hidden well below the implicit 140 cap', (
    tester,
  ) async {
    await _pump(tester, field: _dataField());
    await tester.enterText(find.byType(TextField), 'a' * 10);
    await tester.pump();

    expect(_counters(tester), isEmpty);
    expect(find.text('10/140'), findsNothing);
  });

  testWidgets(
    'counter is still hidden one character before the reveal window',
    (tester) async {
      // Reveal window is 20 chars, so 119 of 140 is the last hidden length.
      await _pump(tester, field: _dataField());
      await tester.enterText(find.byType(TextField), 'a' * 119);
      await tester.pump();

      expect(_counters(tester), isEmpty);
    },
  );

  testWidgets('counter becomes visible as the cap is approached', (
    tester,
  ) async {
    await _pump(tester, field: _dataField());
    await tester.enterText(find.byType(TextField), 'a' * 125);
    await tester.pump();

    expect(find.text('125/140'), findsOneWidget);
  });

  testWidgets('counter is visible AT the cap, where input stops registering', (
    tester,
  ) async {
    await _pump(tester, field: _dataField());
    // maxLength truncates the extra characters — the counter is the only
    // signal the user gets that this happened.
    await tester.enterText(find.byType(TextField), 'a' * 200);
    await tester.pump();

    expect(find.text('140/140'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text.length,
      140,
    );
  });

  testWidgets('an explicit DocField.length drives the counter', (tester) async {
    await _pump(tester, field: _dataField(length: 60));
    await tester.enterText(find.byType(TextField), 'a' * 20);
    await tester.pump();
    expect(_counters(tester), isEmpty);

    await tester.enterText(find.byType(TextField), 'a' * 55);
    await tester.pump();
    expect(find.text('55/60'), findsOneWidget);
  });

  testWidgets('a non-editable field never shows a counter, even over the cap', (
    tester,
  ) async {
    // FieldFactory's `default:` branch renders unsupported field types as a
    // disabled DataField holding whatever the server sent. Nothing can be
    // truncated there, so the counter would be pure noise.
    await _pump(tester, field: _dataField(), value: 'a' * 200, enabled: false);
    await tester.pump();
    expect(_counters(tester), isEmpty);

    await _pump(
      tester,
      field: DocField(
        fieldname: 'name',
        fieldtype: 'Data',
        label: 'Name',
        readOnly: true,
      ),
      value: 'a' * 200,
    );
    await tester.pump();
    expect(_counters(tester), isEmpty);
  });

  testWidgets('no cap (capLength: false) means no counter at any length', (
    tester,
  ) async {
    await _pump(tester, field: _dataField(), capLength: false);
    await tester.enterText(find.byType(TextField), 'a' * 300);
    await tester.pump();

    expect(_counters(tester), isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text.length,
      300,
      reason: 'Single doctypes are mediumtext server-side — no cap at all',
    );
  });
}
