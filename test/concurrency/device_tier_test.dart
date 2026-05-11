import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/device_tier.dart';

void main() {
  test('low tier: RAM ≤ 3GB OR cores ≤ 4 → 2', () {
    expect(DeviceTier.concurrencyForSpecs(totalRamMb: 3000, cores: 8), 2);
    expect(DeviceTier.concurrencyForSpecs(totalRamMb: 8000, cores: 4), 2);
  });

  test('mid tier: RAM ≤ 6GB OR cores ≤ 6 → 4', () {
    expect(DeviceTier.concurrencyForSpecs(totalRamMb: 5000, cores: 8), 4);
    expect(DeviceTier.concurrencyForSpecs(totalRamMb: 12000, cores: 6), 4);
  });

  test('high tier: above both → 8', () {
    expect(DeviceTier.concurrencyForSpecs(totalRamMb: 12000, cores: 8), 8);
  });

  test('override wins when provided', () {
    expect(
      DeviceTier.concurrencyForSpecs(totalRamMb: 2000, cores: 4, override: 6),
      6,
    );
  });

  test(
    'detect() with override returns the override without reading platform',
    () async {
      expect(await DeviceTier.detect(override: 3), 3);
    },
  );

  test(
    'detect() without override returns a positive concurrency level',
    () async {
      // Platform.numberOfProcessors is available in the Dart VM test runner.
      final result = await DeviceTier.detect();
      expect(result, greaterThan(0));
    },
  );
}
