import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/data_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/check_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/numeric_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';

// Simulates a phone screen at 360×640 logical pixels.
const _phoneWidth = 360.0;
const _phoneHeight = 640.0;

// 200-character label — longer than any real-world field name.
const _longLabel =
    'This is an extremely long field label that would trigger a '
    'RenderFlex overflow if the layout did not constrain it with '
    'an Expanded or Flexible widget around the Text child in the Row';

Widget _wrap(Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: _phoneWidth,
        height: _phoneHeight,
        child: SingleChildScrollView(child: FormBuilder(child: child)),
      ),
    ),
  );
}

DocField _field({
  String fieldname = 'f',
  String fieldtype = 'Data',
  String label = _longLabel,
  bool reqd = false,
  String? options,
}) {
  return DocField(
    fieldname: fieldname,
    fieldtype: fieldtype,
    label: label,
    reqd: reqd,
    options: options,
  );
}

void main() {
  // Regression guard: BaseField label is inside Expanded, so even a
  // 200-character label must not produce a RenderFlex overflow error.
  // Acceptance criterion for issue #72.

  testWidgets('DataField — long label does not overflow', (tester) async {
    await tester.pumpWidget(_wrap(DataField(field: _field())));
    await tester.pump();
    // No overflow error thrown = pass.
  });

  testWidgets('DataField required — long label + asterisk does not overflow', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(DataField(field: _field(reqd: true))));
    await tester.pump();
  });

  testWidgets('CheckField — long label does not overflow', (tester) async {
    await tester.pumpWidget(
      _wrap(CheckField(field: _field(fieldtype: 'Check'))),
    );
    await tester.pump();
  });

  testWidgets('NumericField — long label does not overflow', (tester) async {
    await tester.pumpWidget(
      _wrap(NumericField(field: _field(fieldtype: 'Int'))),
    );
    await tester.pump();
  });

  testWidgets('SelectField — long label does not overflow', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SelectField(
          field: _field(fieldtype: 'Select', options: 'A\nB\nC'),
        ),
      ),
    );
    await tester.pump();
  });

  testWidgets('label text is visible and accessible', (tester) async {
    const shortLabel = 'Field Name';
    await tester.pumpWidget(_wrap(DataField(field: _field(label: shortLabel))));
    await tester.pump();
    expect(find.text(shortLabel), findsOneWidget);
  });

  testWidgets('very narrow container (120px) — long label wraps, no overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: FormBuilder(child: DataField(field: _field())),
          ),
        ),
      ),
    );
    await tester.pump();
  });

  testWidgets('multiple fields with long labels in a Column — no overflow', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: _phoneWidth,
            height: _phoneHeight,
            child: SingleChildScrollView(
              child: FormBuilder(
                child: Column(
                  children: [
                    DataField(field: _field(fieldname: 'a')),
                    CheckField(
                      field: _field(fieldname: 'b', fieldtype: 'Check'),
                    ),
                    NumericField(
                      field: _field(fieldname: 'c', fieldtype: 'Float'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  });

  testWidgets('FieldStyle.showLabel=false — label Row not rendered', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DataField(field: _field(), style: const FieldStyle(showLabel: false)),
      ),
    );
    await tester.pump();
    expect(find.text(_longLabel), findsNothing);
  });
}
