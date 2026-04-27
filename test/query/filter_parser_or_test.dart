import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';

DocField f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  final meta = DocTypeMeta(
    name: 'X',
    fields: [f('a', 'Data'), f('b', 'Data')],
  );

  test('AND + OR combined', () {
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['a', '=', '1'],
      ],
      orFilters: [
        ['b', '=', 'X'],
        ['b', '=', 'Y'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains("IFNULL(a, '') = ?"));
    expect(pq.sql, contains(' AND ('));
    expect(pq.sql, contains(' OR '));
    expect(pq.params, ['1', 'X', 'Y']);
  });

  test('only OR filters → single OR group', () {
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: const [],
      orFilters: [
        ['a', '=', 'X'],
        ['b', '=', 'Y'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('WHERE ('));
    expect(pq.sql, contains(' OR '));
  });

  test('only AND filters → no parentheses for OR group', () {
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['a', '=', '1'],
        ['b', '=', '2'],
      ],
      orFilters: const [],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, isNot(contains(' OR ')));
  });
}
