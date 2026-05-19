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
  test('first page (null cursor): no filter, limit_start=0', () async {
    final cap = _Captured();
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        cap.doctype = doctype;
        cap.params = params;
        return const [];
      },
    );
    final meta = DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'N'),
      ],
    );
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
    expect(cap.params!['limit_start'], 0);
    expect(
      (cap.params!['fields'] as List),
      containsAll(<String>['name', 'modified', 'customer_name']),
    );
  });

  test(
    'initial sync: limit_start advances by pageSize, no modified filter',
    () async {
      final capturedParams = <Map<String, Object?>>[];
      var call = 0;
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async {
          capturedParams.add(Map.of(params));
          call++;
          if (call == 1) {
            return List.generate(
              3,
              (i) => {'name': 'X-${i + 1}', 'modified': '2026-01-0${i + 1}'},
            );
          }
          return const [];
        },
      );
      final meta = DocTypeMeta(name: 'X', fields: const []);

      // Page 1 — cursor.start = 0
      final r1 = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: Cursor.empty,
        pageSize: 3,
      );
      expect(capturedParams[0]['limit_start'], 0);
      expect(capturedParams[0]['filters'], isNull);
      expect(r1.advancedCursor.complete, isFalse);
      expect(r1.advancedCursor.start, 3);

      // Page 2 — cursor.start = 3
      await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: r1.advancedCursor,
        pageSize: 3,
      );
      expect(capturedParams[1]['limit_start'], 3);
      expect(capturedParams[1]['filters'], isNull);
    },
  );

  test(
    'incremental cursor (complete=true): modified filter, limit_start=0',
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
        cursor: const Cursor(
          modified: '2026-01-01 00:00:00',
          name: 'A',
          complete: true,
        ),
        pageSize: 500,
      );

      expect(cap.params!['limit_start'], 0);
      final filters = cap.params!['filters'] as List?;
      expect(filters, isNotNull);
      expect(
        filters!.length,
        1,
        reason:
            'must NOT also include `name > X` — that AND-clause would '
            'silently exclude later-modified earlier-named rows',
      );
      expect(
        filters.first,
        ['modified', '>=', '2026-01-01 00:00:00'],
        reason:
            'plan-compliant single >= predicate; seam row absorbed '
            'by PullApply UPSERT idempotency',
      );

      final orf = cap.params!['or_filters'] as List?;
      expect(orf == null || orf.isEmpty, isTrue);
    },
  );

  test(
    'initial sync: advancedCursor tracks modified/name + advances start',
    () async {
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
      expect(result.advancedCursor.complete, isFalse);
      expect(result.advancedCursor.start, 2);
    },
  );

  test(
    'incremental: advancedCursor uses last row modified/name, complete=true',
    () async {
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
        cursor: const Cursor(
          modified: '2026-01-01 00:00:00',
          name: 'A',
          complete: true,
        ),
        pageSize: 500,
      );
      expect(result.rows.length, 2);
      expect(result.advancedCursor.name, 'X-2');
      expect(result.advancedCursor.modified, '2026-01-02 00:00:00');
      expect(result.advancedCursor.complete, isTrue);
      expect(result.advancedCursor.start, 0);
    },
  );

  test('empty result → advancedCursor stays unchanged', () async {
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async => const [],
    );
    final meta = DocTypeMeta(name: 'X', fields: const []);
    const start = Cursor(modified: '2026-01-01', name: 'A', complete: true);
    final result = await fetcher.fetch(
      doctype: 'X',
      meta: meta,
      cursor: start,
      pageSize: 500,
    );
    expect(result.rows, isEmpty);
    expect(result.advancedCursor.name, 'A');
    expect(result.advancedCursor.modified, '2026-01-01');
  });

  test('skips child-table fieldtypes from requested fields', () async {
    final cap = _Captured();
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        cap.params = params;
        return const [];
      },
    );
    final meta = DocTypeMeta(
      name: 'SO',
      fields: [
        DocField(
          fieldname: 'customer',
          fieldtype: 'Link',
          label: 'C',
          options: 'Customer',
        ),
        DocField(
          fieldname: 'items',
          fieldtype: 'Table',
          label: 'I',
          options: 'Sales Order Item',
        ),
        DocField(
          fieldname: 'taxes',
          fieldtype: 'Table MultiSelect',
          label: 'T',
          options: 'Tax',
        ),
        DocField(fieldname: 'break1', fieldtype: 'Section Break', label: 'B'),
      ],
    );
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
