import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  testWidgets('renders one labelled cell per declared in_list_view column', (
    WidgetTester tester,
  ) async {
    final childMeta = DocTypeMeta.fromJson({
      'name': 'TestChildDoc',
      'fields': [
        {
          'fieldname': 'size',
          'fieldtype': 'Data',
          'label': 'Size',
          'in_list_view': 1,
        },
        {
          'fieldname': 'qty',
          'fieldtype': 'Int',
          'label': 'Qty',
          'in_list_view': 1,
        },
      ],
    });
    final field = DocField.fromJson({
      'fieldname': 'child_table',
      'fieldtype': 'Table',
      'label': 'Child Table',
      'options': 'TestChildDoc',
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChildTableField(
            field: field,
            value: const [
              {'size': '500g', 'qty': 3},
            ],
            onChanged: (_) {},
            getMeta: (_) async => childMeta,
            formBuilder:
                (meta, data, onSubmit, {registerSubmit, readOnly = false}) =>
                    const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Size'), findsOneWidget);
    expect(find.textContaining('500g'), findsOneWidget);
    expect(find.textContaining('Qty'), findsOneWidget);
    expect(find.textContaining('3'), findsOneWidget);
  });

  testWidgets('falls back to the single title tile when no columns declared', (
    WidgetTester tester,
  ) async {
    final childMeta = DocTypeMeta.fromJson({
      'name': 'TestChildDoc',
      'fields': [
        {'fieldname': 'size', 'fieldtype': 'Data', 'label': 'Size'},
      ],
    });
    final field = DocField.fromJson({
      'fieldname': 'child_table',
      'fieldtype': 'Table',
      'label': 'Child Table',
      'options': 'TestChildDoc',
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChildTableField(
            field: field,
            value: const [
              {'size': '500g'},
            ],
            onChanged: (_) {},
            getMeta: (_) async => childMeta,
            formBuilder:
                (meta, data, onSubmit, {registerSubmit, readOnly = false}) =>
                    const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Size: 500g'), findsOneWidget);
  });
}
