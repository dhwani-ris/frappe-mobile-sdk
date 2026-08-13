import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  group('ForceUpdateInfo', () {
    test('carries the title and store url handed to it', () async {
      var opened = 0;
      final info = ForceUpdateInfo(
        title: 'Update required',
        storeUrl: 'https://example.test/app',
        openStore: () async => opened++,
      );

      expect(info.title, 'Update required');
      expect(info.storeUrl, 'https://example.test/app');
      await info.openStore();
      expect(opened, 1);
    });
  });

  group('FrappeAppGuard', () {
    testWidgets('renders the child when no base url is configured', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FrappeAppGuard(baseUrl: '', child: Text('inner app')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('inner app'), findsOneWidget);
    });

    testWidgets('an unreachable server does not block the child', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FrappeAppGuard(
            baseUrl: 'http://127.0.0.1:1',
            currentPackageName: 'com.example.test',
            currentVersion: '54',
            child: Text('inner app'),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('inner app'), findsOneWidget);
    });

    testWidgets('changing recheckToken re-runs the status check', (
      tester,
    ) async {
      Widget build(Object token) => MaterialApp(
        home: FrappeAppGuard(
          baseUrl: 'http://127.0.0.1:1',
          currentPackageName: 'com.example.test',
          currentVersion: '54',
          recheckToken: token,
          child: const Text('inner app'),
        ),
      );

      await tester.pumpWidget(build(1));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text('inner app'), findsOneWidget);

      // Assert on the frame pumpWidget itself produces: didUpdateWidget resets
      // to the checking state synchronously, and against an unreachable local
      // port the fail-open path completes within the very next pump — so an
      // extra pump here would race past the state being asserted.
      await tester.pumpWidget(build(2));

      // A re-check is in flight, so the guard is back to its checking state.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('inner app'), findsNothing);

      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text('inner app'), findsOneWidget);
    });
  });
}
