import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode_notifier.dart';

void main() {
  group('OfflineModeNotifier', () {
    test('exposes the initial value', () {
      final n = OfflineModeNotifier(
        const OfflineMode(enabled: false, isPersisted: true),
      );
      expect(n.value.enabled, isFalse);
      expect(n.value.isPersisted, isTrue);
    });

    test('mutates value via setter', () {
      final n = OfflineModeNotifier(
        const OfflineMode(enabled: false, isPersisted: false),
      );
      n.value = const OfflineMode(enabled: true, isPersisted: true);
      expect(n.value.enabled, isTrue);
      expect(n.value.isPersisted, isTrue);
    });
  });
}
