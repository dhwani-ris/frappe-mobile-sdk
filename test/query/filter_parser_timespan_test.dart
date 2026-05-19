import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';

DocField f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  final meta = DocTypeMeta(name: 'T', fields: [
    f('created_at', 'Datetime'),
    f('created_on', 'Date'),
    f('qty', 'Int'),
  ]);

  group('between', () {
    test('Datetime between pair — inclusive', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__t',
        filters: [
          [
            'created_at',
            'between',
            ['2026-01-01 00:00:00', '2026-01-31 23:59:59'],
          ],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains('created_at >= ? AND created_at <= ?'));
      expect(pq.params, ['2026-01-01 00:00:00', '2026-01-31 23:59:59']);
    });

    test('Date between expands end to 23:59:59', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__t',
        filters: [
          [
            'created_on',
            'between',
            ['2026-01-01', '2026-01-31'],
          ],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.params.last, contains('23:59:59'));
    });

    test('Date between expands start to 00:00:00', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__t',
        filters: [
          [
            'created_on',
            'between',
            ['2026-01-01', '2026-01-31'],
          ],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.params.first, contains('00:00:00'));
    });

    test('Int between (non-date) passes through', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__t',
        filters: [
          [
            'qty',
            'between',
            [1, 10],
          ],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.params, [1, 10]);
    });
  });

  group('timespan', () {
    test('expands "this month" to a between', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__t',
        filters: [
          ['created_at', 'timespan', 'this month'],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains('created_at >= ? AND created_at <= ?'));
      expect(pq.params.length, 2);
    });
  });
}
