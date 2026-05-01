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
}
