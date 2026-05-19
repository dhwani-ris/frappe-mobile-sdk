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
    expect(
      merged['x'],
      'set',
      reason: 'ours==base==null → not a local change → takes theirs',
    );
  });

  // Regression for PR#36 round-2 H7: `_eq` used `a == b` for all values,
  // which for List/Map is identity equality in Dart. Two decoded-JSON
  // lists with the same contents always compared as unequal, so the
  // merge treated every list field as locally-changed and silently
  // discarded server updates.

  test('equal-content List: server changes win when local is unchanged', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {
        'tags': ['a', 'b'],
      },
      ours: {
        'tags': ['a', 'b'],
      },
      theirs: {
        'tags': ['a', 'b', 'c'],
      },
    );
    expect(
      merged['tags'],
      ['a', 'b', 'c'],
      reason:
          'ours == base by deep equality → not a local change → takes theirs',
    );
  });

  test('different-content List: local changes win', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {
        'tags': ['a', 'b'],
      },
      ours: {
        'tags': ['a', 'b', 'local'],
      },
      theirs: {
        'tags': ['a', 'b', 'server'],
      },
    );
    expect(merged['tags'], [
      'a',
      'b',
      'local',
    ], reason: 'genuine local-vs-base diff → keeps ours');
  });

  test('equal-content Map: server changes win when local is unchanged', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {
        'meta': {'k': 1},
      },
      ours: {
        'meta': {'k': 1},
      },
      theirs: {
        'meta': {'k': 1, 'new': 2},
      },
    );
    expect(merged['meta'], {'k': 1, 'new': 2});
  });

  test('nested List inside Map compared by deep equality', () {
    final merged = ThreeWayMerge.mergeFields(
      base: {
        'meta': {
          'list': [1, 2],
        },
      },
      ours: {
        'meta': {
          'list': [1, 2],
        },
      },
      theirs: {
        'meta': {
          'list': [1, 2, 3],
        },
      },
    );
    expect(merged['meta'], {
      'list': [1, 2, 3],
    });
  });
}
