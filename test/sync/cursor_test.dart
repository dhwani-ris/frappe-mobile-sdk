import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/cursor.dart';

void main() {
  test('null cursor serializes as null', () {
    expect(Cursor.empty.isNull, isTrue);
    expect(Cursor.empty.toJson(), isNull);
  });

  test('round-trip with values', () {
    final c = Cursor(modified: '2026-01-01 00:00:00', name: 'SO-1');
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
}
