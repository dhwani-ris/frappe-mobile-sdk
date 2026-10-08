// Desk's grid honours two Table docfield flags: `cannot_add_rows` hides
// "Add Row" and `cannot_delete_rows` hides row deletion. Rows stay editable
// either way — the flags restrict the row SET, not the row CONTENT. These tests
// pin the same behaviour for ChildTableField and its path through the form.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

DocField _table({bool noAdd = false, bool noDelete = false}) =>
    DocField.fromJson({
      'fieldname': 'items',
      'fieldtype': 'Table',
      'label': 'Items',
      'options': 'Order Item',
      if (noAdd) 'cannot_add_rows': 1,
      if (noDelete) 'cannot_delete_rows': 1,
    });

final _childMeta = DocTypeMeta.fromJson({
  'name': 'Order Item',
  'istable': 1,
  'fields': [
    {'fieldname': 'item_code', 'fieldtype': 'Data', 'label': 'Item'},
  ],
});

Future<void> _pump(WidgetTester tester, DocField field) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ChildTableField(
            field: field,
            value: const [
              {'item_code': 'SKU-1'},
            ],
            onChanged: (_) {},
            getMeta: (_) async => _childMeta,
            formBuilder: (m, d, o, {registerSubmit, readOnly = false}) {
              registerSubmit?.call(() {});
              return const Text('ChildFormContent');
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('DocField', () {
    test('parses cannot_add_rows / cannot_delete_rows', () {
      final f = _table(noAdd: true, noDelete: true);
      expect(f.cannotAddRows, isTrue);
      expect(f.cannotDeleteRows, isTrue);
      expect(_table().cannotAddRows, isFalse);
      expect(_table().cannotDeleteRows, isFalse);
    });

    test('round-trips both flags through toJson', () {
      final json = _table(noAdd: true, noDelete: true).toJson();
      final again = DocField.fromJson(json);
      expect(again.cannotAddRows, isTrue);
      expect(again.cannotDeleteRows, isTrue);
    });
  });

  group('ChildTableField', () {
    testWidgets('cannot_add_rows hides Add Row but keeps delete', (
      tester,
    ) async {
      await _pump(tester, _table(noAdd: true));
      expect(find.text('Add Row'), findsNothing);
      expect(find.byIcon(Icons.delete), findsOneWidget);
    });

    testWidgets('cannot_delete_rows hides delete but keeps Add Row', (
      tester,
    ) async {
      await _pump(tester, _table(noDelete: true));
      expect(find.text('Add Row'), findsOneWidget);
      expect(find.byIcon(Icons.delete), findsNothing);
    });

    testWidgets('with both flags a row still opens for editing, without '
        'Remove', (tester) async {
      await _pump(tester, _table(noAdd: true, noDelete: true));
      await tester.tap(find.text('SKU-1'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Order Item'), findsOneWidget);
      expect(find.text('Remove'), findsNothing);
    });

    testWidgets('without the flags the edit sheet still offers Remove', (
      tester,
    ) async {
      await _pump(tester, _table());
      await tester.tap(find.text('SKU-1'));
      await tester.pumpAndSettle();
      expect(find.text('Remove'), findsOneWidget);
    });
  });

  testWidgets('the flags survive the form builder', (tester) async {
    final meta = DocTypeMeta.fromJson({
      'name': 'Order',
      'fields': [
        {
          'fieldname': 'items',
          'fieldtype': 'Table',
          'label': 'Items',
          'options': 'Order Item',
          'cannot_add_rows': 1,
          'cannot_delete_rows': 1,
        },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            initialData: const {
              'items': [
                {'item_code': 'SKU-1'},
              ],
            },
            getMeta: (_) async => _childMeta,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final table = tester.widget<ChildTableField>(find.byType(ChildTableField));
    expect(table.field.cannotAddRows, isTrue);
    expect(table.field.cannotDeleteRows, isTrue);
    expect(find.text('Add Row'), findsNothing);
  });
}
