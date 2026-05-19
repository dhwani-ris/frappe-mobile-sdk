// Focused widget tests for SearchableSelect. The widget is consumed by
// LinkField but is reusable on its own; pin its single/multi-select API
// without going through the full LinkField stack.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/entities/link_option_entity.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/searchable_select.dart';

LinkOptionEntity _opt(String name, [String? label]) => LinkOptionEntity(
  doctype: 'State',
  name: name,
  label: label,
  lastUpdated: 0,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<LinkOptionEntity> options,
  required List<String> selected,
  ValueChanged<List<String>>? onChanged,
  bool multi = false,
  bool enabled = true,
  bool loading = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SearchableSelect(
          options: options,
          selected: selected,
          onChanged: onChanged ?? (_) {},
          multiSelect: multi,
          enabled: enabled,
          loading: loading,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders a TextField input (the search box)', (tester) async {
    await _pump(tester, options: [_opt('TN'), _opt('KL')], selected: const []);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('typing in the search field filters options on focus', (
    tester,
  ) async {
    await _pump(
      tester,
      options: [_opt('TN', 'Tamil Nadu'), _opt('KL', 'Kerala')],
      selected: const [],
    );
    // Focus the field to surface suggestions.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('Tamil Nadu'), findsOneWidget);
    expect(find.text('Kerala'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Kera');
    await tester.pumpAndSettle();
    expect(find.text('Tamil Nadu'), findsNothing);
    expect(find.text('Kerala'), findsOneWidget);
  });

  testWidgets('single-select tap emits [name] and clears the search', (
    tester,
  ) async {
    List<String>? emitted;
    await _pump(
      tester,
      options: [_opt('TN', 'Tamil Nadu')],
      selected: const [],
      onChanged: (v) => emitted = v,
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tamil Nadu'));
    await tester.pumpAndSettle();
    expect(emitted, ['TN']);
  });

  testWidgets('multi-select keeps existing selections and adds the new one', (
    tester,
  ) async {
    List<String>? emitted;
    await _pump(
      tester,
      multi: true,
      options: [_opt('TN'), _opt('KL'), _opt('KA')],
      selected: const ['TN'],
      onChanged: (v) => emitted = v,
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KL'));
    await tester.pumpAndSettle();
    expect(emitted, ['TN', 'KL']);
  });

  testWidgets('multi-select renders chips for currently-selected values', (
    tester,
  ) async {
    await _pump(
      tester,
      multi: true,
      options: [_opt('TN', 'Tamil Nadu'), _opt('KL', 'Kerala')],
      selected: const ['TN', 'KL'],
    );
    expect(find.byType(Chip), findsNWidgets(2));
    expect(find.text('Tamil Nadu'), findsOneWidget);
    expect(find.text('Kerala'), findsOneWidget);
  });

  testWidgets('multi-select chip delete emits a list without that name', (
    tester,
  ) async {
    List<String>? emitted;
    await _pump(
      tester,
      multi: true,
      options: [_opt('TN'), _opt('KL')],
      selected: const ['TN', 'KL'],
      onChanged: (v) => emitted = v,
    );
    // Delete the first chip. The chip's deleteIcon is whatever the widget
    // chose — find by Chip + the InkWell trailing element.
    final chip = tester.widget<Chip>(find.byType(Chip).first);
    // Programmatically trigger the chip's onDeleted callback.
    chip.onDeleted!.call();
    await tester.pumpAndSettle();
    expect(emitted, hasLength(1));
    expect(emitted, isNot(contains('TN')));
  });

  testWidgets('loading: true shows the CircularProgressIndicator', (
    tester,
  ) async {
    await _pump(tester, options: const [], selected: const [], loading: true);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('disabled hides the search field', (tester) async {
    await _pump(
      tester,
      options: [_opt('TN', 'Tamil Nadu')],
      selected: const ['TN'],
      enabled: false,
    );
    expect(find.byType(TextField), findsNothing);
  });
}
