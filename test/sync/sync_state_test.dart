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

  test('notifier emits on every distinct snapshot write', () async {
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

  test('notifier short-circuits when next state equals current', () async {
    final n = SyncStateNotifier();
    n.value = n.value.copyWith(isOnline: true);
    final seen = <SyncState>[];
    final sub = n.stream.listen(seen.add);
    // Same value, three times.
    final identical = n.value;
    n.value = identical;
    n.value = identical.copyWith();
    n.value = identical.copyWith(isOnline: true);
    await Future<void>.delayed(Duration.zero);
    expect(
      seen,
      isEmpty,
      reason: 'identical writes must not push to the stream',
    );
    // A genuinely different write still fires.
    n.value = identical.copyWith(isPulling: true);
    await Future<void>.delayed(Duration.zero);
    expect(seen.length, 1);
    expect(seen.last.isPulling, isTrue);
    await sub.cancel();
    await n.close();
  });

  test(
    'recordMetaSyncFailure / clearMetaSyncFailure update observable map',
    () async {
      final n = SyncStateNotifier();
      final seen = <SyncState>[];
      final sub = n.stream.listen(seen.add);

      n.recordMetaSyncFailure('Customer', 'HTTP 500');
      n.recordMetaSyncFailure('Sales Order', 'parse error');
      await Future<void>.delayed(Duration.zero);
      expect(n.value.failedMetaSyncs, {
        'Customer': 'HTTP 500',
        'Sales Order': 'parse error',
      });
      expect(seen.length, 2);

      // Recording the same error for the same doctype short-circuits.
      n.recordMetaSyncFailure('Customer', 'HTTP 500');
      await Future<void>.delayed(Duration.zero);
      expect(seen.length, 2, reason: 'duplicate record must not emit');

      n.clearMetaSyncFailure('Customer');
      await Future<void>.delayed(Duration.zero);
      expect(n.value.failedMetaSyncs, {'Sales Order': 'parse error'});
      expect(seen.length, 3);

      // Clearing a non-existent entry is a no-op.
      n.clearMetaSyncFailure('Ghost');
      await Future<void>.delayed(Duration.zero);
      expect(seen.length, 3);

      await sub.cancel();
      await n.close();
    },
  );

  test('DoctypeSyncState equality and hashCode', () {
    const a = DoctypeSyncState(pulledCount: 10, hasMore: true);
    const b = DoctypeSyncState(pulledCount: 10, hasMore: true);
    const c = DoctypeSyncState(pulledCount: 11, hasMore: true);
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(equals(c)));
  });

  test('QueueSummary equality and hashCode', () {
    const a = QueueSummary(pending: 2, failed: 1);
    const b = QueueSummary(pending: 2, failed: 1);
    const c = QueueSummary(pending: 3, failed: 1);
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(equals(c)));
    expect(QueueSummary.empty, equals(const QueueSummary()));
  });

  test('SyncErrorSummary construction, equality, and hashCode', () {
    final t = DateTime(2026, 1, 1);
    final a = SyncErrorSummary(code: 'NETWORK', message: 'timeout', at: t);
    final b = SyncErrorSummary(code: 'NETWORK', message: 'timeout', at: t);
    final c = SyncErrorSummary(code: 'TIMEOUT', message: 'timeout', at: t);
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(equals(c)));
    expect(a.code, 'NETWORK');
    expect(a.message, 'timeout');
    expect(a.at, t);
  });

  test('SyncState equality treats perDoctype map by value', () {
    final a = SyncState.initial.updatePerDoctype(
      'SEDVR',
      const DoctypeSyncState(pulledCount: 5, hasMore: true),
    );
    final b = SyncState.initial.updatePerDoctype(
      'SEDVR',
      const DoctypeSyncState(pulledCount: 5, hasMore: true),
    );
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    final c = a.updatePerDoctype(
      'SEDVR',
      const DoctypeSyncState(pulledCount: 6, hasMore: true),
    );
    expect(a, isNot(equals(c)));
  });

  // ── plannedPullDoctypes (Fix 4 / SWF-00533) ────────────────────────────────
  // The "of N" denominator PullEngine.run emits at the start of a pull round.
  // Additive field on SyncState — must round-trip through copyWith and be
  // compared BY VALUE (setEquals), or the SyncStateNotifier's equality
  // short-circuit would swallow the emission and the bootstrap bar would show
  // "of 0".

  test('plannedPullDoctypes defaults to empty on SyncState.initial', () {
    const s = SyncState.initial;
    expect(s.plannedPullDoctypes, isEmpty);
  });

  test('copyWith sets plannedPullDoctypes and leaves the original unchanged',
      () {
    const s = SyncState.initial;
    final s2 = s.copyWith(plannedPullDoctypes: {'Member', 'State'});
    expect(s2.plannedPullDoctypes, {'Member', 'State'});
    expect(s.plannedPullDoctypes, isEmpty, reason: 'original unchanged');
  });

  test('copyWith without plannedPullDoctypes preserves the existing set', () {
    final s = SyncState.initial.copyWith(plannedPullDoctypes: {'Member'});
    // A later copyWith that touches an unrelated flag must NOT drop the set.
    final s2 = s.copyWith(isPulling: true);
    expect(s2.plannedPullDoctypes, {'Member'});
  });

  test('SyncState equality treats plannedPullDoctypes by value (setEquals)',
      () {
    final a = SyncState.initial.copyWith(
      plannedPullDoctypes: {'Member', 'State', 'District'},
    );
    // Same members, different insertion order → still equal by value.
    final b = SyncState.initial.copyWith(
      plannedPullDoctypes: {'District', 'Member', 'State'},
    );
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode, reason: 'unordered hash — order-independent');

    final c = a.copyWith(plannedPullDoctypes: {'Member', 'State'});
    expect(a, isNot(equals(c)), reason: 'a different set is a distinct state');
  });

  test(
    'notifier short-circuits an identical plannedPullDoctypes re-assignment',
    () async {
      final n = SyncStateNotifier();
      n.value = n.value.copyWith(plannedPullDoctypes: {'Member', 'State'});
      final seen = <SyncState>[];
      final sub = n.stream.listen(seen.add);
      // Re-assign a value-equal set (new Set instance, same members) → the
      // ValueNotifier-style equality gate must suppress it.
      n.value = n.value.copyWith(plannedPullDoctypes: {'State', 'Member'});
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty, reason: 'value-equal planned set must not emit');
      // A genuinely different set still fires.
      n.value = n.value.copyWith(plannedPullDoctypes: {'Member'});
      await Future<void>.delayed(Duration.zero);
      expect(seen.length, 1);
      expect(seen.last.plannedPullDoctypes, {'Member'});
      await sub.cancel();
      await n.close();
    },
  );
}
