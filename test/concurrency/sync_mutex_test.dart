import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/sync_mutex.dart';

void main() {
  test('tryProtect runs the body to completion when uncontended', () async {
    final m = SyncMutex();
    final r = await m.tryProtect<int>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return 42;
    });
    expect(r, 42);
  });

  test(
    'second concurrent caller returns null while first is in flight',
    () async {
      final m = SyncMutex();
      final firstStarted = Completer<void>();
      final firstFinished = Completer<void>();
      final firstFuture = m.tryProtect<String>(() async {
        firstStarted.complete();
        await firstFinished.future;
        return 'first';
      });
      await firstStarted.future;
      final secondResult = await m.tryProtect<String>(() async => 'second');
      expect(secondResult, isNull, reason: 'mutex held — second must bail');
      firstFinished.complete();
      expect(await firstFuture, 'first');
    },
  );

  test('mutex is released even when body throws', () async {
    final m = SyncMutex();
    await expectLater(
      m.tryProtect<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    // Lock must be released — a follow-up call should run normally.
    final r = await m.tryProtect<int>(() async => 7);
    expect(r, 7);
  });

  test('serial callers (one after another) all run to completion', () async {
    final m = SyncMutex();
    final r1 = await m.tryProtect<int>(() async => 1);
    final r2 = await m.tryProtect<int>(() async => 2);
    final r3 = await m.tryProtect<int>(() async => 3);
    expect([r1, r2, r3], [1, 2, 3]);
  });

  test('protect runs the body to completion when uncontended', () async {
    final m = SyncMutex();
    final r = await m.protect<int>(() async => 99);
    expect(r, 99);
  });

  test(
    'protect waits for the in-flight holder instead of returning null',
    () async {
      final m = SyncMutex();
      final order = <String>[];
      final firstStarted = Completer<void>();
      final firstFinished = Completer<void>();

      final first = m.tryProtect<void>(() async {
        firstStarted.complete();
        await firstFinished.future;
        order.add('first-done');
      });
      await firstStarted.future;

      // Second caller is launched while first is still in flight; must
      // queue, not bail.
      final second = m.protect<int>(() async {
        order.add('second-running');
        return 7;
      });

      // Give the event loop a tick — second should still be parked.
      await Future<void>.delayed(Duration.zero);
      expect(order, isEmpty, reason: 'second must wait for first to finish');

      firstFinished.complete();
      final result = await second;
      await first;

      expect(result, 7);
      expect(order, ['first-done', 'second-running']);
    },
  );

  test('protect releases the mutex when body throws', () async {
    final m = SyncMutex();
    await expectLater(
      m.protect<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
    final r = await m.tryProtect<int>(() async => 11);
    expect(r, 11);
  });

  test('multiple protect waiters serialize FIFO', () async {
    final m = SyncMutex();
    final order = <int>[];
    final firstStarted = Completer<void>();
    final firstFinished = Completer<void>();

    final first = m.tryProtect<void>(() async {
      firstStarted.complete();
      await firstFinished.future;
    });
    await firstStarted.future;

    final waiter1 = m.protect<void>(() async {
      order.add(1);
    });
    final waiter2 = m.protect<void>(() async {
      order.add(2);
    });
    final waiter3 = m.protect<void>(() async {
      order.add(3);
    });

    firstFinished.complete();
    await Future.wait([first, waiter1, waiter2, waiter3]);
    expect(order, [1, 2, 3]);
  });
}
