import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

DocTypeMeta _childMeta() => DocTypeMeta.fromJson({
  'name': 'TestChildDoc',
  'fields': [
    {'fieldname': 'size', 'fieldtype': 'Data', 'label': 'Size'},
  ],
});

DocField _field() => DocField.fromJson({
  'fieldname': 'child_table',
  'fieldtype': 'Table',
  'label': 'Child Table',
  'options': 'TestChildDoc',
});

void main() {
  testWidgets('renders the host notice on the add sheet', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChildTableField(
              field: _field(),
              value: const [],
              onChanged: (_) {},
              getMeta: (_) async => _childMeta(),
              rowNoticeBuilder: (doctype, parentField, row) =>
                  row == null ? 'Save the parent first' : null,
              formBuilder:
                  (meta, data, onSubmit, {registerSubmit, readOnly = false}) {
                    // A real host registers its submit callback from its own build;
                    // without it the sheet's action button spins indefinitely.
                    registerSubmit?.call(() {});
                    return const Text('ChildFormContent');
                  },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Row'));
    await tester.pumpAndSettle();

    expect(find.text('Save the parent first'), findsOneWidget);
  });

  testWidgets('renders no banner when the host returns null', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChildTableField(
              field: _field(),
              value: const [],
              onChanged: (_) {},
              getMeta: (_) async => _childMeta(),
              rowNoticeBuilder: (doctype, parentField, row) => null,
              formBuilder:
                  (meta, data, onSubmit, {registerSubmit, readOnly = false}) {
                    // A real host registers its submit callback from its own build;
                    // without it the sheet's action button spins indefinitely.
                    registerSubmit?.call(() {});
                    return const Text('ChildFormContent');
                  },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add Row'));
    await tester.pumpAndSettle();

    expect(find.text('Save the parent first'), findsNothing);
  });

  testWidgets('passes the existing row to the builder on an edit sheet', (
    tester,
  ) async {
    Map<String, dynamic>? seenRow;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChildTableField(
              field: _field(),
              value: const [
                {'size': '500g'},
              ],
              onChanged: (_) {},
              getMeta: (_) async => _childMeta(),
              rowNoticeBuilder: (doctype, parentField, row) {
                seenRow = row;
                return null;
              },
              formBuilder:
                  (meta, data, onSubmit, {registerSubmit, readOnly = false}) {
                    // A real host registers its submit callback from its own build;
                    // without it the sheet's action button spins indefinitely.
                    registerSubmit?.call(() {});
                    return const Text('ChildFormContent');
                  },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();

    expect(seenRow, isNotNull);
    expect(seenRow!['size'], '500g');
  });
}
