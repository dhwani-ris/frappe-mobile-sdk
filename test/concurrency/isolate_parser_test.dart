import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/isolate_parser.dart';

void main() {
  test('parses list of maps', () async {
    const json = '{"data":[{"a":1},{"a":2}]}';
    final rows = await IsolateParser.parsePageData(json);
    expect(rows.length, 2);
    expect(rows[0]['a'], 1);
  });

  test('empty data list → empty result', () async {
    const json = '{"data":[]}';
    final rows = await IsolateParser.parsePageData(json);
    expect(rows, isEmpty);
  });

  test('missing data key → throws FormatException', () async {
    await expectLater(
      IsolateParser.parsePageData('{"other":1}'),
      throwsFormatException,
    );
  });

  test('large payload still parses correctly', () async {
    final entries = List.generate(200, (i) => '{"id":$i}').join(',');
    final json = '{"data":[$entries]}';
    final rows = await IsolateParser.parsePageData(json);
    expect(rows.length, 200);
    expect(rows.last['id'], 199);
  });

  test('payload over 8 KiB routes through compute() isolate', () async {
    // _inlineThresholdBytes = 8 * 1024 = 8192. Each entry is ~24 chars;
    // 1000 entries → ~24 KB — well past the threshold.
    final entries = List.generate(
      1000,
      (i) => '{"id":$i,"v":"item_$i"}',
    ).join(',');
    final json = '{"data":[$entries]}';
    expect(
      json.length,
      greaterThan(8192),
      reason: 'payload must exceed threshold to exercise the compute() path',
    );
    final rows = await IsolateParser.parsePageData(json);
    expect(rows.length, 1000);
    expect(rows.first['id'], 0);
    expect(rows.last['id'], 999);
  });
}
