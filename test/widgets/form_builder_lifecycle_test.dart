// Pins the FrappeFormBuilder lifecycle contract beyond the snapshot+submit
// tests already in test/. Specifically:
//   - initialData populates the rendered form
//   - changing a field fires onFormDataChanged with the merged map
//   - readOnly mode disables every field
//   - hidden fields and Section Break fields don't render any input
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

DocTypeMeta _meta(List<DocField> fields) =>
    DocTypeMeta(name: 'Customer', fields: fields);

void main() {
  testWidgets('initialData populates the rendered fields', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: _meta([
              DocField(fieldname: 'name', fieldtype: 'Data', label: 'Name'),
              DocField(fieldname: 'age', fieldtype: 'Int', label: 'Age'),
            ]),
            initialData: const {'name': 'Alice', 'age': 30},
          ),
        ),
      ),
    );
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);
  });

  testWidgets('onFormDataChanged fires with the typed value merged in', (
    tester,
  ) async {
    Map<String, dynamic>? lastEmitted;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: _meta([
              DocField(fieldname: 'name', fieldtype: 'Data', label: 'Name'),
            ]),
            onFormDataChanged: (d) => lastEmitted = d,
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const ValueKey('data_name')), 'Bob');
    await tester.pumpAndSettle();
    expect(lastEmitted, isNotNull);
    expect(lastEmitted!['name'], 'Bob');
  });

  testWidgets('readOnly=true disables every TextField', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: _meta([
              DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
              DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
            ]),
            initialData: const {'a': 'x', 'b': 'y'},
            readOnly: true,
          ),
        ),
      ),
    );
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields, isNotEmpty);
    expect(fields.every((f) => f.enabled == false), isTrue);
  });

  testWidgets('hidden fields do not render any widget', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: _meta([
              DocField(
                fieldname: 'visible',
                fieldtype: 'Data',
                label: 'Visible',
              ),
              DocField(
                fieldname: 'secret',
                fieldtype: 'Data',
                label: 'Secret',
                hidden: true,
              ),
            ]),
          ),
        ),
      ),
    );
    expect(find.text('Visible'), findsAtLeastNWidgets(1));
    expect(find.text('Secret'), findsNothing);
    expect(find.byKey(const ValueKey('data_secret')), findsNothing);
  });

  testWidgets('registerSubmit hook fires once with the submit closure', (
    tester,
  ) async {
    var captured = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: _meta([
              DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
            ]),
            registerSubmit: (_) => captured++,
          ),
        ),
      ),
    );
    expect(captured, 1);
  });

  testWidgets('translate hook is applied to field labels', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: _meta([
              DocField(fieldname: 'a', fieldtype: 'Data', label: 'Name'),
            ]),
            translate: (s) => 'TR:$s',
          ),
        ),
      ),
    );
    expect(find.text('TR:Name'), findsAtLeastNWidgets(1));
  });

  testWidgets('section break does not render an input', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: _meta([
              DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
              DocField(fieldname: 'sb', fieldtype: 'Section Break', label: 'S'),
              DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
            ]),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('data_a')), findsOneWidget);
    expect(find.byKey(const ValueKey('data_b')), findsOneWidget);
    expect(find.byKey(const ValueKey('data_sb')), findsNothing);
  });
}
