import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/rating_field.dart';

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
          child: RatingField(field: field, value: value, onChanged: onChanged),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders 5 stars by default', (tester) async {
    await _pump(
      tester,
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star_border), findsNWidgets(5));
  });

  testWidgets('renders 10 stars when options=10', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'r',
        fieldtype: 'Rating',
        label: 'Rate',
        options: '10',
      ),
    );
    expect(
      find.byIcon(Icons.star_border).evaluate().length +
          find.byIcon(Icons.star).evaluate().length,
      10,
    );
  });

  testWidgets('value=3 (int) fills 3 stars', (tester) async {
    await _pump(
      tester,
      value: 3,
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star), findsNWidgets(3));
    expect(find.byIcon(Icons.star_border), findsNWidgets(2));
  });

  testWidgets('value="4" (string) parses and fills 4 stars', (tester) async {
    await _pump(
      tester,
      value: '4',
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star), findsNWidgets(4));
  });

  testWidgets('tapping the 4th star emits rating=4', (tester) async {
    int? emitted;
    await _pump(
      tester,
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
      onChanged: (v) => emitted = v as int?,
    );
    await tester.tap(find.byIcon(Icons.star_border).at(3));
    await tester.pump();
    expect(emitted, 4);
  });

  testWidgets('readOnly stars do not respond to taps', (tester) async {
    int? emitted;
    await _pump(
      tester,
      value: 2,
      field: DocField(
        fieldname: 'r',
        fieldtype: 'Rating',
        label: 'Rate',
        readOnly: true,
      ),
      onChanged: (v) => emitted = v as int?,
    );
    await tester.tap(find.byIcon(Icons.star_border).first);
    await tester.pump();
    expect(emitted, isNull);
  });

  testWidgets('required validator fires on null submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 'r',
        fieldtype: 'Rating',
        label: 'Rate',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Rate is required'), findsOneWidget);
  });
}
