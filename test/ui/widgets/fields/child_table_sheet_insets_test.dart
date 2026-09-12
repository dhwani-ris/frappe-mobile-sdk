import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  testWidgets('the row sheet clears the system navigation bar', (
    WidgetTester tester,
  ) async {
    tester.view.padding = const FakeViewPadding(bottom: 144);
    addTearDown(tester.view.reset);

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
          body: SingleChildScrollView(
            child: ChildTableField(
              field: field,
              value: const [],
              onChanged: (_) {},
              getMeta: (_) async => childMeta,
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
    await tester.tap(find.text('Add Row'));
    await tester.pumpAndSettle();

    // Some Padding inside the sheet must reserve the bottom safe area, or the
    // action row renders under the system navigation bar.
    final paddings = tester
        .widgetList<Padding>(
          find.descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Padding),
          ),
        )
        .map((p) => (p.padding.resolve(TextDirection.ltr)).bottom);

    expect(
      paddings.any((b) => b >= 48.0),
      isTrue,
      reason: 'no Padding in the sheet reserves the bottom safe area',
    );
  });
}
