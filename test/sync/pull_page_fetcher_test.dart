import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_page_fetcher.dart';
import 'package:frappe_mobile_sdk/src/sync/cursor.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

class _Captured {
  String? doctype;
  Map<String, Object?>? params;
}

void main() {
  test('first page (null cursor): no cursor predicate', () async {
    final cap = _Captured();
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        cap.doctype = doctype;
        cap.params = params;
        return const [];
      },
    );
    final meta = DocTypeMeta(name: 'Customer', fields: [
      DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'N'),
    ]);
    await fetcher.fetch(
      doctype: 'Customer',
      meta: meta,
      cursor: Cursor.empty,
      pageSize: 500,
    );
    expect(cap.doctype, 'Customer');
    final filters = cap.params!['filters'] as List?;
    expect(filters == null || filters.isEmpty, isTrue);
    final orFilters = cap.params!['or_filters'] as List?;
    expect(orFilters == null || orFilters.isEmpty, isTrue);
    expect(cap.params!['order_by'], 'modified asc, name asc');
    expect(cap.params!['limit_page_length'], 500);
    expect(
      (cap.params!['fields'] as List),
      containsAll(<String>['name', 'modified', 'customer_name']),
    );
  });

  test(
    'non-empty cursor → filters has modified >= cursor.modified (and ONLY that)',
    () async {
      final cap = _Captured();
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          cap.params = params;
          return const [];
        },
      );
      final meta = DocTypeMeta(name: 'X', fields: const []);
      await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: Cursor(modified: '2026-01-01 00:00:00', name: 'A'),
        pageSize: 500,
      );

      final filters = cap.params!['filters'] as List?;
      expect(filters, isNotNull);
      expect(filters!.length, 1,
          reason:
              'must NOT also include `name > X` — that AND-clause would '
              'silently exclude later-modified earlier-named rows');
      expect(
        filters.first,
        ['modified', '>=', '2026-01-01 00:00:00'],
        reason: 'plan-compliant single >= predicate; seam row absorbed '
            'by PullApply UPSERT idempotency',
      );

      // The earlier buggy `or_filters: [['modified', '>', X]]` shape must
      // NOT be present — its presence + a separate `name > Y` filter is
      // exactly what caused row exclusion.
      final orf = cap.params!['or_filters'] as List?;
      expect(orf == null || orf.isEmpty, isTrue);
    },
  );

  test('returned rows + advancedCursor derived from last row', () async {
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async => [
        {'name': 'X-1', 'modified': '2026-01-01 00:00:00'},
        {'name': 'X-2', 'modified': '2026-01-02 00:00:00'},
      ],
    );
    final meta = DocTypeMeta(name: 'X', fields: const []);
    final result = await fetcher.fetch(
      doctype: 'X',
      meta: meta,
      cursor: Cursor.empty,
      pageSize: 500,
    );
    expect(result.rows.length, 2);
    expect(result.advancedCursor.name, 'X-2');
    expect(result.advancedCursor.modified, '2026-01-02 00:00:00');
  });

  test('empty result → advancedCursor stays unchanged', () async {
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async => const [],
    );
    final meta = DocTypeMeta(name: 'X', fields: const []);
    final start = Cursor(modified: '2026-01-01', name: 'A');
    final result = await fetcher.fetch(
      doctype: 'X',
      meta: meta,
      cursor: start,
      pageSize: 500,
    );
    expect(result.rows, isEmpty);
    expect(result.advancedCursor.name, 'A');
  });

  test('skips child-table fieldtypes from requested fields', () async {
    final cap = _Captured();
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        cap.params = params;
        return const [];
      },
    );
    final meta = DocTypeMeta(name: 'SO', fields: [
      DocField(
          fieldname: 'customer', fieldtype: 'Link', label: 'C',
          options: 'Customer'),
      DocField(
          fieldname: 'items', fieldtype: 'Table', label: 'I',
          options: 'Sales Order Item'),
      DocField(
          fieldname: 'taxes', fieldtype: 'Table MultiSelect',
          label: 'T', options: 'Tax'),
      DocField(fieldname: 'break1', fieldtype: 'Section Break', label: 'B'),
    ]);
    await fetcher.fetch(
      doctype: 'SO',
      meta: meta,
      cursor: Cursor.empty,
      pageSize: 500,
    );
    final fields = (cap.params!['fields'] as List).cast<String>();
    expect(fields, containsAll(['name', 'modified', 'customer']));
    // Layout breaks → no column → skip.
    expect(fields, isNot(contains('break1')));
    // Child tables: Frappe expands them in the response automatically when
    // requested by name; we still include them.
    expect(fields, contains('items'));
    expect(fields, contains('taxes'));
  });
}
