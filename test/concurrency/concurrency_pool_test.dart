import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/concurrency_pool.dart';

void main() {
  test('respects maxConcurrent cap', () async {
    final pool = ConcurrencyPool(maxConcurrent: 2);
    var inFlight = 0;
    var peak = 0;
    final futures = <Future<void>>[];
    for (var i = 0; i < 10; i++) {
      futures.add(pool.submit<void>(() async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
      }));
    }
    await Future.wait(futures);
    expect(peak, lessThanOrEqualTo(2));
  });

  test('returns task result', () async {
    final pool = ConcurrencyPool(maxConcurrent: 1);
    final r = await pool.submit<int>(() async => 42);
    expect(r, 42);
  });

  test('propagates errors', () async {
    final pool = ConcurrencyPool(maxConcurrent: 1);
    await expectLater(
      pool.submit<void>(() async => throw StateError('boom')),
      throwsStateError,
    );
  });

  test('resize raises cap for new tasks', () async {
    final pool = ConcurrencyPool(maxConcurrent: 1);
    pool.resize(4);
    var inFlight = 0;
    var peak = 0;
    final futures = <Future<void>>[];
    for (var i = 0; i < 10; i++) {
      futures.add(pool.submit<void>(() async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        inFlight--;
      }));
    }
    await Future.wait(futures);
    expect(peak, lessThanOrEqualTo(4));
    expect(peak, greaterThanOrEqualTo(2));
  });

  test('FIFO ordering of dispatches under cap=1', () async {
    final pool = ConcurrencyPool(maxConcurrent: 1);
    final seen = <int>[];
    final futs = [
      pool.submit<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        seen.add(1);
      }),
      pool.submit<void>(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        seen.add(2);
      }),
      pool.submit<void>(() async => seen.add(3)),
    ];
    await Future.wait(futs);
    expect(seen, [1, 2, 3]);
  });

  test('error in one task does not poison the pool', () async {
    final pool = ConcurrencyPool(maxConcurrent: 2);
    await expectLater(
      pool.submit<void>(() async => throw StateError('x')),
      throwsStateError,
    );
    final r = await pool.submit<int>(() async => 100);
    expect(r, 100);
  });
}
