import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/document_list_filter_chip.dart';

void main() {
  testWidgets('renders three chips with counts', (tester) async {
    DocumentListFilter? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DocumentListFilterChip(
          counts: const DocumentListFilterCounts(
              all: 100, unsynced: 7, errors: 2),
          value: DocumentListFilter.all,
          onChanged: (v) => selected = v,
        ),
      ),
    ));
    expect(find.text('All 100'), findsOneWidget);
    expect(find.text('Unsynced 7'), findsOneWidget);
    expect(find.text('Errors 2'), findsOneWidget);
    expect(selected, isNull);
  });

  testWidgets('tap changes selection', (tester) async {
    DocumentListFilter? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DocumentListFilterChip(
          counts: const DocumentListFilterCounts(
              all: 100, unsynced: 7, errors: 2),
          value: DocumentListFilter.all,
          onChanged: (v) => selected = v,
        ),
      ),
    ));
    await tester.tap(find.text('Errors 2'));
    await tester.pumpAndSettle();
    expect(selected, DocumentListFilter.errors);
  });

  testWidgets('zero counts still render', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DocumentListFilterChip(
          counts:
              const DocumentListFilterCounts(all: 0, unsynced: 0, errors: 0),
          value: DocumentListFilter.all,
          onChanged: (_) {},
        ),
      ),
    ));
    expect(find.text('All 0'), findsOneWidget);
  });
}
