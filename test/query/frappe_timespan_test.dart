import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/query/frappe_timespan.dart';

void main() {
  final fixed = DateTime.utc(2026, 4, 24, 10, 30, 0); // a Friday
  DateTime nowFn() => fixed;

  test('today → 2026-04-24 00:00 to 23:59', () {
    final r = FrappeTimespan.resolve('today', now: nowFn);
    expect(r.start, '2026-04-24 00:00:00');
    expect(r.end, '2026-04-24 23:59:59');
  });

  test('yesterday', () {
    final r = FrappeTimespan.resolve('yesterday', now: nowFn);
    expect(r.start, '2026-04-23 00:00:00');
    expect(r.end, '2026-04-23 23:59:59');
  });

  test('tomorrow', () {
    final r = FrappeTimespan.resolve('tomorrow', now: nowFn);
    expect(r.start, '2026-04-25 00:00:00');
    expect(r.end, '2026-04-25 23:59:59');
  });

  test('this week — Monday start', () {
    final r = FrappeTimespan.resolve('this week', now: nowFn);
    // Friday 2026-04-24 → week Mon 2026-04-20 … Sun 2026-04-26
    expect(r.start.startsWith('2026-04-20'), isTrue);
    expect(r.end.startsWith('2026-04-26'), isTrue);
  });

  test('this month', () {
    final r = FrappeTimespan.resolve('this month', now: nowFn);
    expect(r.start.startsWith('2026-04-01'), isTrue);
    expect(r.end.startsWith('2026-04-30'), isTrue);
  });

  test('this quarter (Apr 24 → Q2 = Apr 1 to Jun 30)', () {
    final r = FrappeTimespan.resolve('this quarter', now: nowFn);
    expect(r.start.startsWith('2026-04-01'), isTrue);
    expect(r.end.startsWith('2026-06-30'), isTrue);
  });

  test('this year', () {
    final r = FrappeTimespan.resolve('this year', now: nowFn);
    expect(r.start.startsWith('2026-01-01'), isTrue);
    expect(r.end.startsWith('2026-12-31'), isTrue);
  });

  test('last 7 days', () {
    final r = FrappeTimespan.resolve('last 7 days', now: nowFn);
    expect(r.start.startsWith('2026-04-17'), isTrue);
    expect(r.end.startsWith('2026-04-24'), isTrue);
  });

  test('last 30 days', () {
    final r = FrappeTimespan.resolve('last 30 days', now: nowFn);
    expect(r.start.startsWith('2026-03-25'), isTrue);
  });

  test('last N days with arbitrary N', () {
    final r = FrappeTimespan.resolve('last 3 days', now: nowFn);
    expect(r.start.startsWith('2026-04-21'), isTrue);
  });

  test('last week / next week', () {
    final lw = FrappeTimespan.resolve('last week', now: nowFn);
    expect(lw.start.startsWith('2026-04-13'), isTrue);
    final nw = FrappeTimespan.resolve('next week', now: nowFn);
    expect(nw.start.startsWith('2026-04-27'), isTrue);
  });

  test('unknown keyword throws ArgumentError', () {
    expect(() => FrappeTimespan.resolve('banana', now: nowFn),
        throwsA(isA<ArgumentError>()));
  });
}
