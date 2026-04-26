import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/sync_status_bar.dart';

void main() {
  testWidgets('hidden when idle+online', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(isOnline: true);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.text('Offline'), findsNothing);
    expect(find.text('Paused'), findsNothing);
    expect(find.textContaining('Syncing'), findsNothing);
  });

  testWidgets('shows Offline when isOnline=false', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(isOnline: false);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('Offline beats Paused beats Pulling', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(
      isOnline: false,
      isPaused: true,
      isPulling: true,
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Paused'), findsNothing);
  });

  testWidgets('shows Paused when online + paused', (tester) async {
    final n = SyncStateNotifier();
    n.value =
        n.value.copyWith(isOnline: true, isPaused: true, isPulling: true);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('shows Initial sync above Pushing', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(
      isOnline: true,
      isInitialSync: true,
      isPushing: true,
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.text('Initial sync'), findsOneWidget);
  });

  testWidgets('shows Syncing when pushing', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(isOnline: true, isPushing: true);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.textContaining('Syncing'), findsOneWidget);
  });

  testWidgets('shows Pulling when pulling', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(isOnline: true, isPulling: true);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.textContaining('Pulling'), findsOneWidget);
  });

  testWidgets('Uploading beats Pulling', (tester) async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(
      isOnline: true,
      isUploading: true,
      isPulling: true,
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SyncStatusBar(notifier: n))),
    );
    expect(find.text('Uploading'), findsOneWidget);
    expect(find.textContaining('Pulling'), findsNothing);
  });
}
