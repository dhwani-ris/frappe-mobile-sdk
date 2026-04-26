import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/bulk_watermark_probe.dart';

void main() {
  group('BulkWatermarkProbe', () {
    test('detects header and caches bulk endpoint', () async {
      final probe = BulkWatermarkProbe(
        appMethodName: 'my_mobile_app.get_meta_watermarks',
        requester: (method, doctypes) async {
          return BulkProbeResult(
            headerVersion: '1.0',
            rows: [
              {
                'doctype': doctypes.first,
                'modified': '2026-01-01 00:00:00',
              },
            ],
          );
        },
      );
      final result = await probe.detect(candidates: const ['DocType']);
      expect(result.available, isTrue);
      expect(result.version, '1.0');
    });

    test('absence → available=false, no exception', () async {
      final probe = BulkWatermarkProbe(
        appMethodName: 'x.y',
        requester: (method, doctypes) async {
          throw Exception('404');
        },
      );
      final result = await probe.detect(candidates: const ['DocType']);
      expect(result.available, isFalse);
    });

    test('caches after first successful detect', () async {
      var calls = 0;
      final probe = BulkWatermarkProbe(
        appMethodName: 'x.y',
        requester: (method, doctypes) async {
          calls++;
          return BulkProbeResult(headerVersion: '1', rows: const []);
        },
      );
      await probe.detect(candidates: const ['DocType']);
      await probe.detect(candidates: const ['DocType']);
      expect(calls, 1);
    });

    test('cache can be reset (for logout / app restart)', () async {
      var calls = 0;
      final probe = BulkWatermarkProbe(
        appMethodName: 'x.y',
        requester: (method, doctypes) async {
          calls++;
          return BulkProbeResult(headerVersion: '1', rows: const []);
        },
      );
      await probe.detect(candidates: const ['DocType']);
      probe.reset();
      await probe.detect(candidates: const ['DocType']);
      expect(calls, 2);
    });

    test('fetchWatermarks returns rows from requester', () async {
      final probe = BulkWatermarkProbe(
        appMethodName: 'x.y',
        requester: (method, doctypes) async {
          return BulkProbeResult(
            headerVersion: '1',
            rows: doctypes
                .map((d) => {'doctype': d, 'modified': '2026-04-25'})
                .toList(),
          );
        },
      );
      final rows = await probe.fetchWatermarks(['Customer', 'Sales Order']);
      expect(rows.length, 2);
      expect(rows.first['doctype'], 'Customer');
    });
  });
}
