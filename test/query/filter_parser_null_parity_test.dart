import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';

DocField f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  final meta = DocTypeMeta(name: 'X', fields: [f('note', 'Data')]);

  test('is set → IFNULL(col,"") != ""', () {
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['note', 'is', 'set'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains("IFNULL(note, '') != ''"));
    expect(pq.params, isEmpty);
  });

  test('is not set → IFNULL(col,"") = ""', () {
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['note', 'is', 'not set'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains("IFNULL(note, '') = ''"));
    expect(pq.params, isEmpty);
  });

  test('is null → IS NULL', () {
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['note', 'is', null],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('note IS NULL'));
  });

  test('is not null → IS NOT NULL', () {
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['note', 'is not', null],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('note IS NOT NULL'));
  });
}
