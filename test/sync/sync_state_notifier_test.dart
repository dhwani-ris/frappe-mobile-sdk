import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';

void main() {
  group('value setter', () {
    test('initial value is SyncState.initial', () {
      final n = SyncStateNotifier();
      expect(n.value, same(SyncState.initial));
    });

    test('assigning a different value emits on stream', () async {
      final n = SyncStateNotifier();
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);

      n.value = n.value.copyWith(isOnline: true);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, hasLength(1));
      expect(emitted.single.isOnline, isTrue);
      await sub.cancel();
    });

    test('assigning an equal value short-circuits (no emit)', () async {
      final n = SyncStateNotifier();
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);

      n.value = n.value; // same snapshot
      n.value = n.value.copyWith(); // copyWith with no overrides → equal
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isEmpty);
      await sub.cancel();
    });

    test(
      'multiple subscribers each receive every change (broadcast)',
      () async {
        final n = SyncStateNotifier();
        final a = <bool>[];
        final b = <bool>[];
        final subA = n.stream.listen((s) => a.add(s.isOnline));
        final subB = n.stream.listen((s) => b.add(s.isOnline));

        n.value = n.value.copyWith(isOnline: true);
        n.value = n.value.copyWith(isOnline: false);
        await Future<void>.delayed(Duration.zero);

        expect(a, [true, false]);
        expect(b, [true, false]);
        await subA.cancel();
        await subB.cancel();
      },
    );
  });

  group('recordMetaSyncFailure / clearMetaSyncFailure', () {
    test('record adds the entry and emits', () async {
      final n = SyncStateNotifier();
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);

      n.recordMetaSyncFailure('Customer', 'NETWORK');
      await Future<void>.delayed(Duration.zero);

      expect(emitted.single.failedMetaSyncs, {'Customer': 'NETWORK'});
      await sub.cancel();
    });

    test('record is idempotent on identical (doctype, error)', () async {
      final n = SyncStateNotifier();
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);

      n.recordMetaSyncFailure('Customer', 'NETWORK');
      n.recordMetaSyncFailure('Customer', 'NETWORK');
      await Future<void>.delayed(Duration.zero);

      expect(
        emitted,
        hasLength(1),
        reason: 'second record with same payload must short-circuit',
      );
      await sub.cancel();
    });

    test(
      'record on the same doctype with a new error replaces the value',
      () async {
        final n = SyncStateNotifier();
        n.recordMetaSyncFailure('Customer', 'NETWORK');
        n.recordMetaSyncFailure('Customer', 'TIMEOUT');
        expect(n.value.failedMetaSyncs, {'Customer': 'TIMEOUT'});
      },
    );

    test('clear removes only the specified doctype', () {
      final n = SyncStateNotifier();
      n.recordMetaSyncFailure('Customer', 'NETWORK');
      n.recordMetaSyncFailure('Supplier', 'TIMEOUT');
      n.clearMetaSyncFailure('Customer');
      expect(n.value.failedMetaSyncs, {'Supplier': 'TIMEOUT'});
    });

    test('clear of a non-existent doctype is a no-op', () async {
      final n = SyncStateNotifier();
      n.recordMetaSyncFailure('Customer', 'NETWORK');
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);
      n.clearMetaSyncFailure('Item');
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
      await sub.cancel();
    });
  });

  group('recordLastError / clearLastError', () {
    test('recordLastError sets lastError and emits', () async {
      final n = SyncStateNotifier();
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);

      final err = SyncErrorSummary(
        code: 'PULL_FAILED',
        message: 'boom',
        at: DateTime(2026, 5, 18, 10),
      );
      n.recordLastError(err);
      await Future<void>.delayed(Duration.zero);

      expect(emitted.single.lastError, err);
      await sub.cancel();
    });

    test('recording an identical error is a no-op', () async {
      final n = SyncStateNotifier();
      final err = SyncErrorSummary(
        code: 'X',
        message: 'msg',
        at: DateTime(2026, 1, 1),
      );
      n.recordLastError(err);
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);
      n.recordLastError(err);
      await Future<void>.delayed(Duration.zero);

      expect(emitted, isEmpty);
      await sub.cancel();
    });

    test(
      'clearLastError flips lastError to null and preserves other fields',
      () async {
        final n = SyncStateNotifier();
        n.value = n.value.copyWith(isOnline: true);
        n.recordLastError(
          SyncErrorSummary(code: 'X', message: 'y', at: DateTime(2026)),
        );
        expect(n.value.lastError, isNotNull);
        n.clearLastError();
        expect(n.value.lastError, isNull);
        expect(
          n.value.isOnline,
          isTrue,
          reason: 'clearLastError must preserve unrelated state',
        );
      },
    );

    test('clearLastError on a null lastError is a no-op', () async {
      final n = SyncStateNotifier();
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);
      n.clearLastError();
      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
      await sub.cancel();
    });
  });

  test(
    'close prevents further emissions but value getter still works',
    () async {
      final n = SyncStateNotifier();
      final emitted = <SyncState>[];
      final sub = n.stream.listen(emitted.add);

      n.value = n.value.copyWith(isOnline: true);
      await n.close();

      // After close, the broadcast stream is done — no further events.
      // Subsequent assignments throw because StreamController.add on a closed
      // controller throws StateError.
      expect(
        () => n.value = n.value.copyWith(isOnline: false),
        throwsStateError,
      );

      await sub.cancel();
      expect(emitted, hasLength(1));
    },
  );
}
