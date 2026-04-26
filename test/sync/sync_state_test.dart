import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';

void main() {
  test('default state is offline-unknown + idle', () {
    const s = SyncState.initial;
    expect(s.isOnline, isFalse);
    expect(s.isPulling, isFalse);
    expect(s.isPushing, isFalse);
    expect(s.isUploading, isFalse);
    expect(s.isInitialSync, isFalse);
    expect(s.isPaused, isFalse);
  });

  test('copyWith updates flags immutably', () {
    const s = SyncState.initial;
    final s2 = s.copyWith(isPulling: true);
    expect(s2.isPulling, isTrue);
    expect(s.isPulling, isFalse, reason: 'original unchanged');
  });

  test('updatePerDoctype creates or replaces entry', () {
    const s = SyncState.initial;
    final s2 = s.updatePerDoctype(
      'SEDVR',
      const DoctypeSyncState(
        pulledCount: 500,
        lastPageSize: 500,
        hasMore: true,
      ),
    );
    expect(s2.perDoctype['SEDVR']!.pulledCount, 500);
    final s3 = s2.updatePerDoctype(
      'SEDVR',
      const DoctypeSyncState(
        pulledCount: 1000,
        lastPageSize: 500,
        hasMore: true,
      ),
    );
    expect(s3.perDoctype['SEDVR']!.pulledCount, 1000);
    // Original snapshot still has 500 — confirms immutability of perDoctype.
    expect(s2.perDoctype['SEDVR']!.pulledCount, 500);
  });

  test('notifier emits on every snapshot write', () async {
    final n = SyncStateNotifier();
    final seen = <SyncState>[];
    final sub = n.stream.listen(seen.add);
    n.value = n.value.copyWith(isOnline: true);
    n.value = n.value.copyWith(isPulling: true);
    await Future<void>.delayed(Duration.zero);
    expect(seen.length, 2);
    expect(seen.last.isPulling, isTrue);
    await sub.cancel();
    await n.close();
  });
}
