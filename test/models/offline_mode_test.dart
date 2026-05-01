import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';

void main() {
  group('OfflineMode', () {
    test('fallback is online and unpersisted', () {
      expect(OfflineMode.fallback.enabled, isFalse);
      expect(OfflineMode.fallback.isPersisted, isFalse);
    });

    test('equality based on both fields', () {
      const a = OfflineMode(enabled: true, isPersisted: true);
      const b = OfflineMode(enabled: true, isPersisted: true);
      const c = OfflineMode(enabled: true, isPersisted: false);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, equals(b.hashCode));
    });
  });
}
