import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/delete_cascade_prompt.dart';

void main() {
  testWidgets('shows per-doctype counts', (tester) async {
    DeleteCascadeAction? chose;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              chose = await showDeleteCascadePrompt(
                ctx,
                rootName: 'ABC-001',
                blockedBy: const {
                  'Sales Invoice': ['INV-1', 'INV-2', 'INV-3'],
                },
              );
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ABC-001'), findsOneWidget);
    expect(find.textContaining('Sales Invoice'), findsOneWidget);
    expect(find.textContaining('3'), findsAtLeastNWidgets(1));
    await tester.tap(find.text('Delete all'));
    await tester.pumpAndSettle();
    expect(chose, DeleteCascadeAction.deleteAll);
  });

  testWidgets('Fix manually returns fixManually', (tester) async {
    DeleteCascadeAction? chose;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              chose = await showDeleteCascadePrompt(
                ctx,
                rootName: 'X',
                blockedBy: const {
                  'A': ['1'],
                },
              );
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix manually'));
    await tester.pumpAndSettle();
    expect(chose, DeleteCascadeAction.fixManually);
  });

  testWidgets('Cancel returns cancel', (tester) async {
    DeleteCascadeAction? chose;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              chose = await showDeleteCascadePrompt(
                ctx,
                rootName: 'X',
                blockedBy: const {
                  'A': ['1'],
                },
              );
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(chose, DeleteCascadeAction.cancel);
  });
}
