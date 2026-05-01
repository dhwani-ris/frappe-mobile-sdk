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

  test('round-trip preserves complete=true through JSON', () {
    const c = Cursor(modified: '2024-01-01', name: 'X', complete: true);
    final json = jsonEncode(c.toJson());
    final back = Cursor.fromJson(jsonDecode(json) as Map<String, dynamic>?);
    expect(back.complete, isTrue);
  });
}
