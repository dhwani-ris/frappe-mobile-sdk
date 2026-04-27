import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/three_way_merge.dart';

void main() {
  test('no local changes → takes theirs', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {'name': 'A', 'age': 10},
      ours: {'name': 'A', 'age': 10},
      theirs: {'name': 'A', 'age': 15},
    );
    expect(merged['age'], 15);
  });

  test('local changed → keeps ours', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {'name': 'A', 'age': 10},
      ours: {'name': 'A', 'age': 20},
      theirs: {'name': 'A', 'age': 15},
    );
    expect(merged['age'], 20);
  });

  test('both changed same field → local wins (LWW favoring local)', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {'age': 10},
      ours: {'age': 22},
      theirs: {'age': 15},
    );
    expect(merged['age'], 22);
  });

  test('field added on server, untouched locally → takes server add', () {
    final merged = ThreeWayMerge.mergeFields(
      base: const {},
      ours: const {},
      theirs: {'new_field': 'X'},
    );
    expect(merged['new_field'], 'X');
  });

  test('field added locally, untouched on server → keeps local', () {
    final merged = ThreeWayMerge.mergeFields(
      base: const {},
      ours: {'new_field': 'local'},
      theirs: const {},
    );
    expect(merged['new_field'], 'local');
  });

  test('null vs missing distinguished correctly', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {'x': null},
      ours: {'x': null},
      theirs: {'x': 'set'},
    );
    expect(merged['x'], 'set',
        reason: 'ours==base==null → not a local change → takes theirs');
  });
}
