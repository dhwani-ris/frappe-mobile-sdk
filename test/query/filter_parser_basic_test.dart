import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_errors.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

DocTypeMeta meta() => DocTypeMeta(name: 'Customer', fields: [
      f('customer_name', 'Data'),
      f('age', 'Int'),
      f('is_active', 'Check'),
      f('balance', 'Float'),
      f('territory', 'Link', options: 'Territory'),
    ]);

void main() {
  test('no filters → just LIMIT + OFFSET', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: const [],
      orFilters: const [],
      page: 0,
      pageSize: 50,
    );
    expect(pq.sql, contains('LIMIT 50 OFFSET 0'));
    expect(pq.sql, isNot(contains('WHERE')));
    expect(pq.params, isEmpty);
  });

  test('string equality uses IFNULL wrapping', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: [
        ['customer_name', '=', 'ACME'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains("IFNULL(customer_name, '') = ?"));
    expect(pq.params, ['ACME']);
  });

  test('int equality uses IFNULL(col, 0)', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: [
        ['age', '=', 10],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('IFNULL(age, 0) = ?'));
    expect(pq.params, [10]);
  });

  test('check (tinyint/boolean) equality uses IFNULL(col, 0)', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: [
        ['is_active', '=', 1],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('IFNULL(is_active, 0) = ?'));
  });

  test('!= operator', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: [
        ['customer_name', '!=', 'Stale'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains("IFNULL(customer_name, '') != ?"));
  });

  test('< / <= / > / >= on numeric — no IFNULL wrap (null excluded)', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: [
        ['age', '>', 18],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('age > ?'));
    expect(pq.sql, isNot(contains('IFNULL(age')));
  });

  test('multiple filters combined with AND', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: [
        ['customer_name', '=', 'X'],
        ['age', '>', 18],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains(' AND '));
    expect(pq.params, ['X', 18]);
  });

  test('order_by single column ASC default', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: const [],
      orderBy: 'customer_name',
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('ORDER BY customer_name ASC'));
  });

  test('order_by with explicit DESC', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: const [],
      orderBy: 'customer_name DESC',
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('ORDER BY customer_name DESC'));
  });

  test('order_by column not on meta → FilterParseError', () {
    expect(
      () => FilterParser.toSql(
        meta: meta(),
        tableName: 'docs__customer',
        filters: const [],
        orderBy: 'ghost_col',
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<FilterParseError>()),
    );
  });

  test('pagination offset', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: const [],
      orderBy: null,
      page: 3,
      pageSize: 25,
    );
    expect(pq.sql, contains('LIMIT 25 OFFSET 75'));
  });

  test('unknown column → FilterParseError', () {
    expect(
      () => FilterParser.toSql(
        meta: meta(),
        tableName: 'docs__customer',
        filters: [
          ['ghost', '=', 'X'],
        ],
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<FilterParseError>()),
    );
  });

  test('unknown operator → FilterParseError', () {
    expect(
      () => FilterParser.toSql(
        meta: meta(),
        tableName: 'docs__customer',
        filters: [
          ['customer_name', 'regex', 'X'],
        ],
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<FilterParseError>()),
    );
  });

  test('system columns (sync_status, modified) are filterable', () {
    final pq = FilterParser.toSql(
      meta: meta(),
      tableName: 'docs__customer',
      filters: [
        ['sync_status', '=', 'dirty'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains("IFNULL(sync_status, '') = ?"));
    expect(pq.params, ['dirty']);
  });
}
