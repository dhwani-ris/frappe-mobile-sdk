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
}
