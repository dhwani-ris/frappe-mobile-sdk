import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/query/filter_parser.dart';

DocField f(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, label: n);

void main() {
  final meta = DocTypeMeta(name: 'X', fields: [f('status', 'Data')]);

  group('in / not in', () {
    test('non-empty in → IN (?, ?)', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['status', 'in', ['A', 'B']],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains('status IN (?, ?)'));
      expect(pq.params, ['A', 'B']);
    });

    test('empty in → short-circuit 1=0', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['status', 'in', const []],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains('1=0'));
    });

    test('non-empty not in → NOT IN (?,?)', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['status', 'not in', ['X']],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains('status NOT IN (?)'));
      expect(pq.params, ['X']);
    });

    test('empty not in → 1=1', () {
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['status', 'not in', const []],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains('1=1'));
    });
  });

  group('like / not like', () {
    final metaWithNorm = DocTypeMeta(
      name: 'Contact',
      titleField: 'full_name',
      fields: [f('full_name', 'Data'), f('email', 'Data')],
    );

    test('like on non-norm field → IFNULL(col,"") LIKE ? raw value', () {
      final pq = FilterParser.toSql(
        meta: metaWithNorm,
        tableName: 'docs__contact',
        filters: [
          ['email', 'like', '%@example.com'],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains("IFNULL(email, '') LIKE ?"));
      expect(pq.params, ['%@example.com']);
    });

    test('like on norm-target field → IFNULL(col__norm,"") LIKE normalized', () {
      final pq = FilterParser.toSql(
        meta: metaWithNorm,
        tableName: 'docs__contact',
        filters: [
          ['full_name', 'like', '%ANKIT%'],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains("IFNULL(full_name__norm, '') LIKE ?"));
      expect(pq.params, ['%ankit%']);
    });

    test('like with accents normalized', () {
      final pq = FilterParser.toSql(
        meta: metaWithNorm,
        tableName: 'docs__contact',
        filters: [
          ['full_name', 'like', '%Café%'],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.params, ['%cafe%']);
    });

    test('not like works the same', () {
      final pq = FilterParser.toSql(
        meta: metaWithNorm,
        tableName: 'docs__contact',
        filters: [
          ['full_name', 'not like', '%test%'],
        ],
        page: 0,
        pageSize: 10,
      );
      expect(pq.sql, contains("IFNULL(full_name__norm, '') NOT LIKE ?"));
    });
  });
}
