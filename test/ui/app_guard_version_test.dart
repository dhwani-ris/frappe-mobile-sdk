import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  group('appUpdateRequired — build numbers compare as a minimum', () {
    test('blocks a build below the floor', () {
      expect(appUpdateRequired(expected: '54', current: '53'), isTrue);
    });

    test('allows a build exactly at the floor', () {
      expect(appUpdateRequired(expected: '54', current: '54'), isFalse);
    });

    test('allows a build above the floor — the bug this fixes', () {
      expect(appUpdateRequired(expected: '54', current: '55'), isFalse);
    });

    test('allows a much newer build', () {
      expect(appUpdateRequired(expected: '54', current: '120'), isFalse);
    });
  });

  group('appUpdateRequired — non-integer values keep exact-pin behaviour', () {
    test('blocks when a version name differs', () {
      expect(
        appUpdateRequired(expected: '1.0.0', current: '1.0.2-staging'),
        isTrue,
      );
    });

    test('allows when a version name matches exactly', () {
      expect(appUpdateRequired(expected: '1.0.2', current: '1.0.2'), isFalse);
    });

    test('treats an integer floor against an unparseable current as a mismatch',
        () {
      expect(appUpdateRequired(expected: '54', current: ''), isTrue);
    });
  });

  group('appUpdateRequired — an unset floor never blocks', () {
    test('null expected', () {
      expect(appUpdateRequired(expected: null, current: '53'), isFalse);
    });

    test('empty expected', () {
      expect(appUpdateRequired(expected: '', current: '53'), isFalse);
    });

    test('whitespace-only expected', () {
      expect(appUpdateRequired(expected: '   ', current: '53'), isFalse);
    });
  });

  group('appUpdateRequired — whitespace is tolerated', () {
    test('padded values still compare numerically', () {
      expect(appUpdateRequired(expected: ' 54 ', current: ' 53 '), isTrue);
      expect(appUpdateRequired(expected: ' 54 ', current: ' 54 '), isFalse);
    });
  });
}
