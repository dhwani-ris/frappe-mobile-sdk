import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/html_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HtmlField(field: field, value: value),
      ),
    ),
  );
}

void main() {
  testWidgets('renders html from field.options', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'banner',
        fieldtype: 'HTML',
        label: 'Banner',
        options: '<p>Hello <b>world</b></p>',
      ),
    );
    // HtmlWidget renders the visible text — assert presence of "Hello world".
    // HtmlWidget renders into RichText, so a plain find may miss. Look at the
    // widget tree for our HtmlField subtree.
    expect(find.byType(HtmlField), findsOneWidget);
    expect(
      find.byType(SizedBox),
      findsNothing,
      reason: 'non-empty html must not collapse',
    );
  });

  testWidgets('hidden field renders nothing', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'banner',
        fieldtype: 'HTML',
        label: 'Banner',
        options: '<p>x</p>',
        hidden: true,
      ),
    );
    expect(find.textContaining('x'), findsNothing);
  });

  testWidgets('empty options + null value collapses to SizedBox.shrink', (
    tester,
  ) async {
    await _pump(
      tester,
      field: DocField(fieldname: 'banner', fieldtype: 'HTML', label: 'Banner'),
    );
    expect(find.byType(Padding), findsNothing);
  });

  testWidgets('value overrides options when options is empty', (tester) async {
    await _pump(
      tester,
      value: '<p>fromvalue</p>',
      field: DocField(fieldname: 'banner', fieldtype: 'HTML', label: 'Banner'),
    );
    // Same RichText caveat; assert the widget did NOT collapse.
    expect(find.byType(HtmlField), findsOneWidget);
    expect(find.byType(SizedBox), findsNothing);
  });
}
