import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/cursor.dart';

void main() {
  test('null cursor serializes as null', () {
    expect(Cursor.empty.isNull, isTrue);
    expect(Cursor.empty.toJson(), isNull);
  });

  test('round-trip with values', () {
    const c = Cursor(modified: '2026-01-01 00:00:00', name: 'SO-1');
    final json = jsonEncode(c.toJson());
    final back = Cursor.fromJson(jsonDecode(json) as Map<String, dynamic>?);
    expect(back.modified, '2026-01-01 00:00:00');
    expect(back.name, 'SO-1');
    expect(back.start, 0);
  });

  test('toJson NEVER writes the legacy `start` offset field (keyset)', () {
    // Post-2026-07-23 keyset-resume fix: pagination is keyset, `limit_start`
    // is always 0. Persisting an offset would resurrect the deep-OFFSET
    // behaviour the fix removed, so even a non-zero in-memory `start` must
    // NOT leak into the on-disk JSON.
    const c = Cursor(modified: '2026-01-01', name: 'X', start: 12000);
    final json = c.toJson()!;
    expect(json.containsKey('start'), isFalse);
    expect(
      json.keys.toSet(),
      {'modified', 'name', 'complete'},
      reason: 'SIG-9 on-disk shape is exactly {modified,name,complete}',
    );
  });

  test('start=0 is also omitted from toJson (keyset — start never written)',
      () {
    const c = Cursor(modified: '2026-01-01', name: 'X', start: 0);
    final json = c.toJson()!;
    expect(json.containsKey('start'), isFalse);
  });

  test(
    'fromJson tolerates a legacy {..,"start":N} cursor (no crash, keyset '
    'semantics)',
    () {
      // A device upgrading from the offset era holds a cursor that still
      // carries a stale `start`. fromJson MUST parse it without crashing; the
      // offset is then simply ignored by the keyset pager. complete=false +
      // non-null (modified,name) is reinterpreted as a keyset resume point.
      final c = Cursor.fromJson({
        'modified': '2026-01-01 00:00:00',
        'name': 'CUST-500',
        'complete': false,
        'start': 12000,
      });
      expect(c.modified, '2026-01-01 00:00:00');
      expect(c.name, 'CUST-500');
      expect(c.complete, isFalse);
      expect(
        c.isNull,
        isFalse,
        reason: 'a non-null (modified,name) is a keyset resume point',
      );
      // Re-serialising the migrated cursor drops the stale offset entirely.
      expect(c.toJson()!.containsKey('start'), isFalse);
    },
  );

  test('fromJson missing "start" defaults to 0', () {
    final c = Cursor.fromJson({'modified': '2026-01-01', 'name': 'X'});
    expect(c.start, 0);
  });

  test('markComplete resets start to 0', () {
    const c = Cursor(
      modified: '2026-01-01',
      name: 'X',
      complete: false,
      start: 500,
    );
    final done = c.markComplete();
    expect(done.complete, isTrue);
    expect(done.start, 0);
  });

  test('fromJson(null) → empty', () {
    expect(Cursor.fromJson(null).isNull, isTrue);
  });

  test('advance produces a new cursor', () {
    final c = Cursor.empty.advance(modified: '2026-01-01', name: 'A');
    expect(c.name, 'A');
    expect(c.modified, '2026-01-01');
  });

  test('toJson roundtrips the complete flag', () {
    const c = Cursor(modified: '2024-01-01', name: 'X', complete: true);
    final back = Cursor.fromJson(c.toJson());
    expect(back.complete, isTrue);
    expect(back.modified, '2024-01-01');
    expect(back.name, 'X');
  });

  test('default cursor has complete=false', () {
    expect(const Cursor().complete, isFalse);
    expect(Cursor.empty.complete, isFalse);
  });

  test('fromJson missing "complete" defaults to false', () {
    final c = Cursor.fromJson({'modified': '2024-01-01', 'name': 'X'});
    expect(c.complete, isFalse);
  });

  test('markComplete returns a copy with complete=true', () {
    const c = Cursor(modified: 'm', name: 'n', complete: false);
    final done = c.markComplete();
    expect(done.complete, isTrue);
    expect(done.modified, 'm');
    expect(done.name, 'n');
  });

  test('equality: two cursors with same values are equal', () {
    const a = Cursor(modified: '2026-01-01', name: 'SO-1', complete: true);
    const b = Cursor(modified: '2026-01-01', name: 'SO-1', complete: true);
    const c = Cursor(modified: '2026-01-01', name: 'SO-2', complete: true);
    const d = Cursor(
      modified: '2026-01-01',
      name: 'SO-1',
      complete: true,
      start: 100,
    );
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
    expect(a, isNot(equals(d)), reason: 'differing start breaks equality');
    expect(Cursor.empty, equals(const Cursor()));
  });

  test('hashCode: equal cursors have same hashCode', () {
    const a = Cursor(modified: '2026-01-01', name: 'X', complete: false);
    const b = Cursor(modified: '2026-01-01', name: 'X', complete: false);
    expect(a.hashCode, b.hashCode);
  });

  test('round-trip preserves complete=true through JSON', () {
    const c = Cursor(modified: '2024-01-01', name: 'X', complete: true);
    final json = jsonEncode(c.toJson());
    final back = Cursor.fromJson(jsonDecode(json) as Map<String, dynamic>?);
    expect(back.complete, isTrue);
  });
}
