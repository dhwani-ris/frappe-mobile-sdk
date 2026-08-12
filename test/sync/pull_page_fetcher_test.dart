import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_columns.dart';
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
        return const ListHttpPage([]);
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
            return ListHttpPage(
              List.generate(
                3,
                (i) => {'name': 'X-${i + 1}', 'modified': '2026-01-0${i + 1}'},
              ),
            );
          }
          return const ListHttpPage([]);
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
          return const ListHttpPage([]);
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
        listHttp: (doctype, params) async => const ListHttpPage([
          {'name': 'X-1', 'modified': '2026-01-01 00:00:00'},
          {'name': 'X-2', 'modified': '2026-01-02 00:00:00'},
        ]),
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
    'incremental: advancedCursor uses max row modified/name, complete=true',
    () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage([
          {'name': 'X-1', 'modified': '2026-01-01 00:00:00'},
          {'name': 'X-2', 'modified': '2026-01-02 00:00:00'},
        ]),
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
      listHttp: (doctype, params) async => const ListHttpPage([]),
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
        return const ListHttpPage([]);
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

  group('out-of-order pages (listFullDocs bulk-fetch path)', () {
    // `bulkGetWithChildren` is a `names in (...)` fetch: nothing in the request
    // obliges the server to honour `order_by`. Taking `rows.last` as the
    // watermark therefore trusted an ordering the SDK never established.
    final scrambled = <Map<String, dynamic>>[
      {'name': 'X-3', 'modified': '2026-01-03 00:00:00'},
      {'name': 'X-1', 'modified': '2026-01-01 00:00:00'},
      {'name': 'X-2', 'modified': '2026-01-02 00:00:00'},
    ];

    test('incremental: cursor takes the page MAX, not rows.last', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => ListHttpPage(scrambled),
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: DocTypeMeta(name: 'X', fields: const []),
        cursor: const Cursor(
          modified: '2026-01-01 00:00:00',
          name: 'A',
          complete: true,
        ),
        pageSize: 500,
      );
      expect(
        result.advancedCursor.modified,
        '2026-01-03 00:00:00',
        reason:
            'rows.last is X-2; the true high-water mark is X-3. Taking the '
            'last row lets the watermark regress below rows already applied.',
      );
      expect(result.advancedCursor.name, 'X-3');
    });

    test('incremental: a page whose last row carries the page MINIMUM does not '
        'pin the watermark at the incoming cursor', () async {
      // This is the stall-guard trap: if the scrambled last row happens to
      // equal the incoming cursor, PullEngine breaks and persists the cursor
      // at that minimum. Because server ordering is deterministic for the
      // same query, every later sync reproduces it — the doctype's watermark
      // is pinned forever and rows past page 1 are never pulled again.
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage([
          {'name': 'X-9', 'modified': '2026-01-09 00:00:00'},
          {'name': 'A', 'modified': '2026-01-01 00:00:00'},
        ]),
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: DocTypeMeta(name: 'X', fields: const []),
        cursor: const Cursor(
          modified: '2026-01-01 00:00:00',
          name: 'A',
          complete: true,
        ),
        pageSize: 500,
      );
      expect(result.advancedCursor.modified, '2026-01-09 00:00:00');
      expect(result.advancedCursor.name, 'X-9');
    });

    test('initial: cursor tracks the page MAX while start advances', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => ListHttpPage(scrambled),
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: DocTypeMeta(name: 'X', fields: const []),
        cursor: Cursor.empty,
        pageSize: 500,
      );
      expect(result.advancedCursor.modified, '2026-01-03 00:00:00');
      expect(result.advancedCursor.start, 3);
    });
  });

  group('permission-filtered pages (namesScanned)', () {
    final meta = DocTypeMeta(name: 'X', fields: const []);

    test(
      'initial: zero docs but names scanned → pageFiltered, start advances by '
      'the name count',
      () async {
        final fetcher = PullPageFetcher(
          listHttp: (doctype, params) async =>
              const ListHttpPage([], namesScanned: 100),
        );
        final result = await fetcher.fetch(
          doctype: 'X',
          meta: meta,
          cursor: Cursor.empty,
          pageSize: 100,
        );
        expect(result.rows, isEmpty);
        expect(
          result.pageFiltered,
          isTrue,
          reason:
              'every name on the page was dropped by the per-doc permission '
              'gate — that is a skip, not end-of-stream',
        );
        expect(result.advancedCursor.start, 100);
      },
    );

    test(
      'initial: offset advances by names scanned, not docs returned',
      () async {
        final fetcher = PullPageFetcher(
          listHttp: (doctype, params) async => const ListHttpPage([
            {'name': 'X-1', 'modified': '2026-01-01 00:00:00'},
          ], namesScanned: 100),
        );
        final result = await fetcher.fetch(
          doctype: 'X',
          meta: meta,
          cursor: Cursor.empty,
          pageSize: 100,
        );
        expect(
          result.advancedCursor.start,
          100,
          reason:
              'advancing by rows.length (1) would re-request the 99 filtered '
              'names on every page, growing the overlap without bound',
        );
        expect(result.pageFiltered, isFalse);
      },
    );

    test('incremental: advances past a fully-filtered window', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage(
          [],
          namesScanned: 100,
          scannedMaxModified: '2026-01-05 00:00:00',
          scannedMaxName: 'Z',
        ),
      );
      const start = Cursor(
        modified: '2026-01-01 00:00:00',
        name: 'A',
        complete: true,
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: start,
        pageSize: 100,
      );
      expect(
        result.pageFiltered,
        isTrue,
        reason:
            'incremental pins limit_start at 0, so the only way past a '
            'denied block is to move `modified`. Leaving the cursor put '
            'makes the next sync issue the byte-identical query, get the '
            'identical empty window, and strand every row BEHIND the block '
            'forever',
      );
      expect(result.advancedCursor.modified, '2026-01-05 00:00:00');
      expect(
        result.advancedCursor.name,
        'Z',
        reason:
            'the window is `modified asc, name asc`-ordered, so its max name '
            'is the last row that was inside the window and denied',
      );
      expect(
        result.advancedCursor.complete,
        isTrue,
        reason:
            'the skip must stay incremental; dropping back to an offset pull '
            'would re-scan the whole table',
      );
    });

    test('incremental: a same-second window still stops', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage(
          [],
          namesScanned: 100,
          scannedMaxModified: '2026-01-01 00:00:00',
          scannedMaxName: 'Z',
        ),
      );
      const start = Cursor(
        modified: '2026-01-01 00:00:00',
        name: 'A',
        complete: true,
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: start,
        pageSize: 100,
      );
      expect(
        result.pageFiltered,
        isFalse,
        reason:
            'a window whose max `modified` only EQUALS the cursor cannot '
            'move the `modified >=` predicate, so no progress is possible: '
            'report end-of-stream and retry next cycle',
      );
      expect(result.advancedCursor.modified, '2026-01-01 00:00:00');
      expect(
        result.advancedCursor.name,
        'A',
        reason:
            '`name` must never advance without `modified`: bumping it alone '
            'leaves the next request byte-identical (an infinite loop in '
            'PullEngine), and the SyncService tie-group skip — which drops '
            'rows with `modified == cursor.modified && name <= cursor.name` '
            '— would then discard READABLE rows',
      );
    });

    test('incremental: an older window max never moves the watermark '
        'backwards', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage(
          [],
          namesScanned: 100,
          scannedMaxModified: '2025-12-31 00:00:00',
          scannedMaxName: 'Z',
        ),
      );
      const start = Cursor(
        modified: '2026-01-01 00:00:00',
        name: 'A',
        complete: true,
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: start,
        pageSize: 100,
      );
      expect(
        result.pageFiltered,
        isFalse,
        reason:
            'the compare is strictly-greater, so a window max below the '
            'cursor is not progress',
      );
      expect(
        result.advancedCursor.modified,
        '2026-01-01 00:00:00',
        reason:
            'a watermark must never move backwards — that would re-pull '
            'and re-apply everything between the two timestamps',
      );
      expect(result.advancedCursor.name, 'A');
    });

    test('incremental: a null window max degrades to stop-and-retry '
        '(inert, not broken)', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async =>
            const ListHttpPage([], namesScanned: 100),
      );
      const start = Cursor(
        modified: '2026-01-01 00:00:00',
        name: 'A',
        complete: true,
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: start,
        pageSize: 100,
      );
      expect(
        result.pageFiltered,
        isFalse,
        reason:
            'this is the path a deployment that refuses to project '
            '`modified` on the name query lands on: with no watermark to '
            'advance to, the fix is simply inert and the pre-fix '
            'stop-and-retry behaviour stands — no crash, no loss',
      );
      expect(result.advancedCursor.modified, '2026-01-01 00:00:00');
      expect(result.advancedCursor.name, 'A');
    });

    test('incremental: advances from a null incoming watermark', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage(
          [],
          namesScanned: 100,
          scannedMaxModified: '2026-01-05 00:00:00',
          scannedMaxName: 'Z',
        ),
      );
      const start = Cursor(complete: true);
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: start,
        pageSize: 100,
      );
      expect(
        result.pageFiltered,
        isTrue,
        reason:
            'a complete cursor with no `modified` is a real state (fetch '
            'attaches the `modified >=` filter only when it is non-null), so '
            'the window it scanned genuinely starts at the head of the '
            'table and any non-null max is progress',
      );
      expect(result.advancedCursor.modified, '2026-01-05 00:00:00');
      expect(result.advancedCursor.name, 'Z');
      expect(result.advancedCursor.complete, isTrue);
    });

    test('namesScanned == 0 is genuine end-of-stream', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async =>
            const ListHttpPage([], namesScanned: 0),
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: Cursor.empty,
        pageSize: 100,
      );
      expect(result.pageFiltered, isFalse);
      expect(result.advancedCursor.start, 0);
    });

    test('namesScanned == 0 wins over an advancing watermark', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage(
          [],
          namesScanned: 0,
          scannedMaxModified: '2026-01-05 00:00:00',
          scannedMaxName: 'Z',
        ),
      );
      const start = Cursor(
        modified: '2026-01-01 00:00:00',
        name: 'A',
        complete: true,
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: start,
        pageSize: 100,
      );
      expect(
        result.pageFiltered,
        isFalse,
        reason:
            'the endpoint consumed nothing, so this is real end-of-stream: a '
            'watermark reported over an empty window must not be mistaken '
            'for progress, or every incremental pull would advance its '
            'cursor on the final empty page',
      );
      expect(result.advancedCursor.modified, '2026-01-01 00:00:00');
      expect(result.advancedCursor.name, 'A');
    });

    test('namesScanned == null (plain get_list path) keeps rows.length as the '
        'offset step', () async {
      final fetcher = PullPageFetcher(
        listHttp: (doctype, params) async => const ListHttpPage([
          {'name': 'X-1', 'modified': '2026-01-01 00:00:00'},
          {'name': 'X-2', 'modified': '2026-01-02 00:00:00'},
        ]),
      );
      final result = await fetcher.fetch(
        doctype: 'X',
        meta: meta,
        cursor: Cursor.empty,
        pageSize: 100,
      );
      expect(result.advancedCursor.start, 2);
    });
  });

  test('always requests the server-owned audit fields', () async {
    // `owner` / `creation` / `modified_by` are real columns on every DocType
    // table but are never declared in `meta.fields`, so they must be asked
    // for explicitly — otherwise PullApply persists NULL and any offline
    // filter on them matches nothing.
    final cap = _Captured();
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        cap.params = params;
        return const ListHttpPage([]);
      },
    );
    await fetcher.fetch(
      doctype: 'X',
      meta: DocTypeMeta(name: 'X', fields: const []),
      cursor: Cursor.empty,
      pageSize: 500,
    );
    final fields = (cap.params!['fields'] as List).cast<String>();
    expect(fields, containsAll(serverAuditColumnNames));
  });
}
