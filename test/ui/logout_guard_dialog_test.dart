import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/dialogs/logout_guard_dialog.dart';

void main() {
  testWidgets('shows pending count + three actions', (tester) async {
    LogoutGuardAction? chose;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              chose = await showLogoutGuardDialog(ctx, unsyncedCount: 5);
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    expect(find.textContaining('5 unsynced'), findsOneWidget);
    expect(find.text('Sync now'), findsOneWidget);
    expect(find.text('Log out anyway'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();
    expect(chose, LogoutGuardAction.syncNow);
  });

  testWidgets('Cancel returns cancel', (tester) async {
    LogoutGuardAction? chose;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              chose = await showLogoutGuardDialog(ctx, unsyncedCount: 1);
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
    expect(chose, LogoutGuardAction.cancel);
  });

  testWidgets('Log out anyway returns logoutAnyway', (tester) async {
    LogoutGuardAction? chose;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              chose = await showLogoutGuardDialog(ctx, unsyncedCount: 1);
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Log out anyway'));
    await tester.pumpAndSettle();
    expect(chose, LogoutGuardAction.logoutAnyway);
  });
}
