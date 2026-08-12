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

  test(
    'standard audit column (owner) emits real bound SQL, is NOT dropped',
    () {
      final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
      // `owner` is materialized on every parent `docs__*` table, so the clause
      // must reach SQL. It used to be silently dropped, which made the offline
      // result a SUPERSET of the server query (rows owned by other users).
      final pq = FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['owner', '=', 'someone@example.com'],
          ['a', '=', 'keep'],
        ],
        page: 0,
        pageSize: 10,
      );
      // BARE `owner = ?`, deliberately not `IFNULL(owner, '') = ?`: the
      // wrapper is non-sargable, so it could not use the `ix_*_owner` index and
      // `owner = <me>` was a guaranteed full scan. Equivalent for every
      // realistic query — a NULL owner is excluded either way — and a
      // meta-derived column beside it still gets the wrapper.
      expect(pq.sql, contains('owner = ?'));
      expect(pq.sql, isNot(contains("IFNULL(owner, '')")));
      expect(pq.sql, contains("IFNULL(a, '') = ?"));
      expect(pq.params, containsAllInOrder(['someone@example.com', 'keep']));
    },
  );

  test('creation emits real bound SQL (range comparison)', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['creation', '>=', '2026-01-01 00:00:00'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('creation >= ?'));
    expect(pq.params, ['2026-01-01 00:00:00']);
  });

  test('modified_by is filterable on a parent doctype', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['modified_by', '=', 'editor@example.com'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains('modified_by = ?'));
    expect(pq.sql, isNot(contains("IFNULL(modified_by, '')")));
    expect(pq.params, ['editor@example.com']);
  });

  test('!= on an audit column KEEPS the IFNULL wrapper', () {
    // Not symmetric with `=` on purpose: with the wrapper a NULL owner counts as
    // "not alice" and the row is returned; bare `owner != ?` yields NULL and
    // would silently start excluding those rows.
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    final pq = FilterParser.toSql(
      meta: meta,
      tableName: 'docs__x',
      filters: [
        ['owner', '!=', 'someone@example.com'],
      ],
      page: 0,
      pageSize: 10,
    );
    expect(pq.sql, contains("IFNULL(owner, '') != ?"));
  });

  test('audit columns are NOT whitelisted on a child table (isTable)', () {
    // `child_schema.dart` emits no audit columns, so whitelisting them for a
    // child doctype would generate SQL against a column that does not exist.
    // Throwing is correct — and is what any other absent column does.
    final meta = DocTypeMeta(
      name: 'C',
      fields: [f('a', 'Data')],
      isTable: true,
    );
    for (final col in ['owner', 'creation', 'modified_by']) {
      expect(
        () => FilterParser.toSql(
          meta: meta,
          tableName: 'docs__c',
          filters: [
            [col, '=', 'x'],
          ],
          page: 0,
          pageSize: 10,
        ),
        throwsA(isA<FilterParseError>()),
        reason: '$col must not be whitelisted for a child table',
      );
    }
  });

  test('genuinely-unknown column still throws (not silently dropped)', () {
    final meta = DocTypeMeta(name: 'X', fields: [f('a', 'Data')]);
    expect(
      () => FilterParser.toSql(
        meta: meta,
        tableName: 'docs__x',
        filters: [
          ['nonexistent_field', '=', 'x'],
        ],
        page: 0,
        pageSize: 10,
      ),
      throwsA(isA<FilterParseError>()),
    );
  });
}
