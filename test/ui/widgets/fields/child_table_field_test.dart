// Covers the visible-state surface of ChildTableField. Avoids driving the
// add/edit dialog (which requires a real meta + formBuilder closure) — those
// flows are exercised indirectly by FrappeFormBuilder integration tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/child_table_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  required List<dynamic> rows,
  ValueChanged<List<dynamic>>? onChanged,
  bool enabled = true,
  Future<DocTypeMeta> Function(String)? getMeta,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ChildTableField(
            field: field,
            value: rows,
            onChanged: onChanged,
            enabled: enabled,
            getMeta: getMeta,
          ),
        ),
      ),
    ),
  );
}

void main() {
  final field = DocField(
    fieldname: 'items',
    fieldtype: 'Table',
    label: 'Order Items',
    options: 'Order Item',
  );

  testWidgets('renders the label and "Add Row" when editable', (tester) async {
    await _pump(tester, field: field, rows: const [], onChanged: (_) {});
    expect(find.text('Order Items'), findsOneWidget);
    expect(find.text('Add Row'), findsOneWidget);
  });

  testWidgets('empty list shows "No records added" placeholder', (
    tester,
  ) async {
    await _pump(tester, field: field, rows: const [], onChanged: (_) {});
    expect(find.text('No records added'), findsOneWidget);
  });

  testWidgets('readOnly field hides the Add Row button', (tester) async {
    final readField = DocField(
      fieldname: 'items',
      fieldtype: 'Table',
      label: 'Items',
      options: 'Order Item',
      readOnly: true,
    );
    await _pump(tester, field: readField, rows: const [], onChanged: (_) {});
    expect(find.text('Add Row'), findsNothing);
  });

  testWidgets('non-editable (no onChanged) hides Add Row', (tester) async {
    await _pump(tester, field: field, rows: const []);
    expect(find.text('Add Row'), findsNothing);
  });

  testWidgets('renders one Card per row', (tester) async {
    await _pump(
      tester,
      field: field,
      rows: const [
        {'item_code': 'SKU-1', 'qty': 2},
        {'item_code': 'SKU-2', 'qty': 5},
      ],
      onChanged: (_) {},
    );
    expect(find.byType(Card), findsNWidgets(2));
  });

  testWidgets('row title falls back to item_code when meta is unavailable', (
    tester,
  ) async {
    await _pump(
      tester,
      field: field,
      rows: const [
        {'item_code': 'SKU-1', 'qty': 2},
      ],
      onChanged: (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('SKU-1'), findsOneWidget);
  });

  testWidgets('subtitle joins amount/qty/rate fields', (tester) async {
    await _pump(
      tester,
      field: field,
      rows: const [
        {'item_code': 'SKU-1', 'qty': 2, 'rate': 100, 'amount': 200},
      ],
      onChanged: (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('amount: 200 | qty: 2 | rate: 100'), findsOneWidget);
  });

  testWidgets('delete trash icon removes the row via onChanged', (
    tester,
  ) async {
    List<dynamic>? after;
    await _pump(
      tester,
      field: field,
      rows: const [
        {'item_code': 'SKU-1'},
        {'item_code': 'SKU-2'},
      ],
      onChanged: (next) => after = next,
    );
    await tester.tap(find.byIcon(Icons.delete).first);
    await tester.pump();
    expect(after, hasLength(1));
    expect((after!.single as Map)['item_code'], 'SKU-2');
  });

  testWidgets('readOnly hides the per-row delete icon', (tester) async {
    final readField = DocField(
      fieldname: 'items',
      fieldtype: 'Table',
      label: 'Items',
      options: 'Order Item',
      readOnly: true,
    );
    await _pump(
      tester,
      field: readField,
      rows: const [
        {'item_code': 'SKU-1'},
      ],
      onChanged: (_) {},
    );
    expect(find.byIcon(Icons.delete), findsNothing);
  });

  testWidgets('title uses meta.titleField when getMeta returns one', (
    tester,
  ) async {
    await _pump(
      tester,
      field: field,
      rows: const [
        {'description': 'Pretty title', 'item_code': 'SKU-1'},
      ],
      onChanged: (_) {},
      getMeta: (_) async => DocTypeMeta(
        name: 'Order Item',
        titleField: 'description',
        fields: const [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Pretty title'), findsOneWidget);
  });
}
