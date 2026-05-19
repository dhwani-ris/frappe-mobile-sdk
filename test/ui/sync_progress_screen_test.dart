import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/ui/screens/sync_progress_screen.dart';

void main() {
  testWidgets('shows per-doctype rows', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value
        .copyWith(isOnline: true, isInitialSync: true)
        .updatePerDoctype(
          'Customer',
          const DoctypeSyncState(
              pulledCount: 42, lastPageSize: 500, hasMore: true),
        )
        .updatePerDoctype(
          'Order',
          const DoctypeSyncState(pulledCount: 0),
        );
    await tester.pumpWidget(MaterialApp(
      home: SyncProgressScreen(
        notifier: n,
        onPause: () async {},
        onCancel: () async {},
      ),
    ));
    expect(find.textContaining('Customer'), findsOneWidget);
    expect(find.textContaining('Order'), findsOneWidget);
    expect(find.textContaining('42'), findsOneWidget);
  });

  testWidgets('Pause triggers callback', (tester) async {
    var paused = false;
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(isInitialSync: true);
    await tester.pumpWidget(MaterialApp(
      home: SyncProgressScreen(
        notifier: n,
        onPause: () async => paused = true,
        onCancel: () async {},
      ),
    ));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Pause'));
    await tester.pump();
    expect(paused, isTrue);
  });

  testWidgets('Cancel triggers callback', (tester) async {
    var cancelled = false;
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(isInitialSync: true);
    await tester.pumpWidget(MaterialApp(
      home: SyncProgressScreen(
        notifier: n,
        onPause: () async {},
        onCancel: () async => cancelled = true,
      ),
    ));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    expect(cancelled, isTrue);
  });

  testWidgets('shows progress bar that reflects completion ratio',
      (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value
        .copyWith(isOnline: true, isInitialSync: true)
        .updatePerDoctype(
          'A',
          DoctypeSyncState(
              pulledCount: 10, completedAt: DateTime.utc(2026, 1, 1)),
        )
        .updatePerDoctype(
          'B',
          const DoctypeSyncState(pulledCount: 0),
        );
    await tester.pumpWidget(MaterialApp(
      home: SyncProgressScreen(
        notifier: n,
        onPause: () async {},
        onCancel: () async {},
      ),
    ));
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 0.5);
  });
}
