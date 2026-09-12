import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds a DocTypeMeta with [tabCount] Tab Break / Data field pairs.
/// All metas share the same [name] so the name-only guard does NOT fire.
DocTypeMeta _tabMeta(String name, int tabCount) => DocTypeMeta(
  name: name,
  fields: [
    for (var i = 0; i < tabCount; i++) ...[
      DocField(
        fieldname: 'tab_$i',
        fieldtype: 'Tab Break',
        label: 'Tab ${i + 1}',
      ),
      DocField(
        fieldname: 'field_$i',
        fieldtype: 'Data',
        label: 'Field ${i + 1}',
      ),
    ],
  ],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
    'didUpdateWidget rebuilds TabController when tab count changes with same doctype name',
    (WidgetTester tester) async {
      // Start with 2 tabs.
      DocTypeMeta currentMeta = _tabMeta('SameDoc', 2);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    ElevatedButton(
                      key: const ValueKey('swap_meta'),
                      onPressed: () => setState(() {
                        // Swap to 3 tabs — same doctype name, structural change.
                        currentMeta = _tabMeta('SameDoc', 3);
                      }),
                      child: const Text('Swap'),
                    ),
                    Expanded(child: FrappeFormBuilder(meta: currentMeta)),
                  ],
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(2));

      // Swap meta: same name, one extra tab.  Without the tab-count guard in
      // didUpdateWidget, the stale TabController(length: 2) stays alive while
      // the rebuilt TabBar tries to render 3 tabs — Flutter asserts
      // "tabs.length == controller.length" and the test fails with a FlutterError.
      await tester.tap(find.byKey(const ValueKey('swap_meta')));
      await tester.pumpAndSettle();

      // After fix: TabController is rebuilt for 3 tabs; no assertion error.
      expect(find.byType(Tab), findsNWidgets(3));
    },
  );

  testWidgets(
    'didUpdateWidget rebuilds when the implicit leading tab appears — same raw '
    'count, different effective count (M7)',
    (WidgetTester tester) async {
      // Both metas carry the SAME raw Tab Break count (2) and the same name, so
      // the old static _tabCount guard would NOT fire. Moving a data field to
      // sit BEFORE the first Tab Break makes the builder synthesise an implicit
      // leading "Details" tab, taking the effective count to 3 — which
      // _effectiveTabCount detects. Without it a TabController(length:3) would
      // outlive a TabBar rendering 2 tabs and assert.
      //
      // This used to be exercised by hiding a middle Tab Break. That no longer
      // changes the count: a hidden layout break keeps its container, so the
      // tab is still produced (see `_buildTabsFor`). The implicit leading tab
      // is now the remaining case where effective and raw counts differ, and it
      // is what keeps this guard honest.
      DocField tab(int i) => DocField(
        fieldname: 'tab_$i',
        fieldtype: 'Tab Break',
        label: 'Tab ${i + 1}',
      );
      DocField data(int i) =>
          DocField(fieldname: 'field_$i', fieldtype: 'Data', label: 'F$i');

      DocTypeMeta meta({required bool leadingContent}) => DocTypeMeta(
        name: 'SameDoc',
        fields: [
          if (leadingContent) data(9),
          tab(0),
          if (!leadingContent) data(9),
          data(0),
          tab(1),
          data(1),
        ],
      );

      DocTypeMeta currentMeta = meta(leadingContent: true); // 3 effective tabs

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    ElevatedButton(
                      key: const ValueKey('drop_leading'),
                      onPressed: () => setState(
                        () => currentMeta = meta(leadingContent: false),
                      ),
                      child: const Text('Drop'),
                    ),
                    Expanded(child: FrappeFormBuilder(meta: currentMeta)),
                  ],
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(3));

      await tester.tap(find.byKey(const ValueKey('drop_leading')));
      await tester.pumpAndSettle();

      // Effective count dropped to 2; controller rebuilt, no assertion.
      expect(find.byType(Tab), findsNWidgets(2));
    },
  );

  testWidgets(
    'hiding a Tab Break keeps its tab, so the effective count does not change '
    '(M7b)',
    (WidgetTester tester) async {
      // Pins the boundary rule from the other direction: `hidden` on a layout
      // break suppresses nothing structural here, so the tab survives and the
      // TabController length is unchanged. Frappe Desk likewise constructs the
      // container regardless of `hidden` (layout.js render() -> make_tab).
      DocField tab(int i, {bool hidden = false}) => DocField(
        fieldname: 'tab_$i',
        fieldtype: 'Tab Break',
        label: 'Tab ${i + 1}',
        hidden: hidden,
      );
      DocField data(int i) =>
          DocField(fieldname: 'field_$i', fieldtype: 'Data', label: 'F$i');

      DocTypeMeta meta({required bool hideMiddle}) => DocTypeMeta(
        name: 'SameDoc',
        fields: [
          tab(0),
          data(0),
          tab(1, hidden: hideMiddle),
          data(1),
          tab(2),
          data(2),
        ],
      );

      DocTypeMeta currentMeta = meta(hideMiddle: false);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Column(
                  children: [
                    ElevatedButton(
                      key: const ValueKey('hide_tab'),
                      onPressed: () =>
                          setState(() => currentMeta = meta(hideMiddle: true)),
                      child: const Text('Hide'),
                    ),
                    Expanded(child: FrappeFormBuilder(meta: currentMeta)),
                  ],
                );
              },
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(Tab), findsNWidgets(3));

      await tester.tap(find.byKey(const ValueKey('hide_tab')));
      await tester.pumpAndSettle();

      expect(
        find.byType(Tab),
        findsNWidgets(3),
        reason: 'the hidden Tab Break still opens its container',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
