import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_errors.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';

DocField f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  test('injection attempt in column name rejected', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    expect(
      () => FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['a; DROP TABLE docs__x; --', '=', 'X'],
        ],
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<FilterParseError>()),
    );
  });

  test('4-tuple cross-doctype filter → UnsupportedFilterError', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    expect(
      () => FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['Child DocType', 'status', '=', 'Active'],
        ],
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<UnsupportedFilterError>()),
    );
  });

  test('value is parameter-bound — never string-concatenated', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['a', '=', "ev'il' OR 1=1 --"],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.params, contains("ev'il' OR 1=1 --"));
    expect(pq.sql, isNot(contains("ev'il'")));
  });

  test('order_by direction other than ASC/DESC rejected', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    expect(
      () => FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: const [],
        orderBy: 'a; DROP TABLE x; --',
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<FilterParseError>()),
    );
  });

  test('malformed filter (wrong arity) → FilterParseError', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    expect(
      () => FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['a', '='],
        ],
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<FilterParseError>()),
    );
  });
}
