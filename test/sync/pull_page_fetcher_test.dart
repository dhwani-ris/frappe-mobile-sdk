import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_page_fetcher.dart';
import 'package:frappe_mobile_sdk/src/sync/cursor.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

/// Records every params map the fetcher passed to `listHttp`, in order, so a
/// test can assert the per-phase filter / order / limit_start shape. This is
/// the plain-fake `ListHttpFn` seam the repo convention prescribes (no
/// mockito/mocktail).
class _Recorder {
  final List<Map<String, Object?>> calls = [];
  String? lastDoctype;

  /// Build a `ListHttpFn` that records params and returns [rowsPerCall] for
  /// the matching call index (defaulting to `[]` past the end).
  ListHttpFn responder(List<List<Map<String, dynamic>>> rowsPerCall) {
    return (doctype, params) async {
      lastDoctype = doctype;
      final i = calls.length;
      calls.add(Map.of(params));
      return i < rowsPerCall.length ? rowsPerCall[i] : const [];
    };
  }
}

DocTypeMeta _meta() =>
    DocTypeMeta(name: 'X', fields: [DocField(fieldname: 'v', fieldtype: 'Data', label: 'V')]);

void main() {
  // ── First page (INITIAL, null cursor) ────────────────────────────────
  test('first page (null cursor): unfiltered, order modified asc/name asc, '
      'limit_start=0, single request', () async {
    final rec = _Recorder();
    final fetcher = PullPageFetcher(listHttp: rec.responder([[]]));
    await fetcher.fetch(
      doctype: 'Customer',
      meta: DocTypeMeta(
        name: 'Customer',
        fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'N')],
      ),
      cursor: Cursor.empty,
      pageSize: 500,
    );
    expect(rec.lastDoctype, 'Customer');
    expect(rec.calls.length, 1, reason: 'INITIAL first page is a single request');
    final p = rec.calls.single;
    final filters = p['filters'] as List?;
    expect(filters == null || filters.isEmpty, isTrue, reason: 'unfiltered');
    final orFilters = p['or_filters'] as List?;
    expect(orFilters == null || orFilters.isEmpty, isTrue);
    expect(p['order_by'], 'modified asc, name asc');
    expect(p['limit_page_length'], 500);
    expect(p['limit_start'], 0);
    expect(
      p['fields'] as List,
      containsAll(<String>['name', 'modified', 'customer_name']),
    );
  });

  // ── Resume (complete=false) pages by KEYSET, never offset ─────────────
  test('resume (complete=false): pages by KEYSET — limit_start is ALWAYS 0, '
      'never an offset restart', () async {
    // Page 1 = null cursor (unfiltered). Page 2 uses the advanced cursor and
    // MUST be a keyset fetch (a `modified` filter, limit_start 0) — NOT an
    // unfiltered offset-N restart. This is the reported bug, at fetcher level.
    final rec = _Recorder();
    final fetcher = PullPageFetcher(
      listHttp: rec.responder([
        // page 1 (unfiltered)
        [
          {'name': 'X-1', 'modified': '2026-01-01 00:00:01', 'v': 'a'},
          {'name': 'X-2', 'modified': '2026-01-01 00:00:02', 'v': 'b'},
          {'name': 'X-3', 'modified': '2026-01-01 00:00:03', 'v': 'c'},
        ],
        // page 2 Phase A (tie-drain) — empty (unique modified)
        [],
        // page 2 Phase B (advance)
        [],
      ]),
    );
    final meta = _meta();

    final r1 = await fetcher.fetch(
      doctype: 'X',
      meta: meta,
      cursor: Cursor.empty,
      pageSize: 3,
    );
    expect(rec.calls[0]['limit_start'], 0);
    expect(rec.calls[0]['filters'], isNull, reason: 'page 1 is unfiltered');
    expect(r1.advancedCursor.complete, isFalse);
    expect(r1.advancedCursor.modified, '2026-01-01 00:00:03');
    expect(r1.advancedCursor.name, 'X-3');

    await fetcher.fetch(
      doctype: 'X',
      meta: meta,
      cursor: r1.advancedCursor,
      pageSize: 3,
    );
    // Page 2 is keyset — Phase A carries the anchor `modified`.
    final phaseA = rec.calls[1];
    expect(phaseA['limit_start'], 0, reason: 'keyset: limit_start never > 0');
    final aFilters = (phaseA['filters'] as List).cast<List>();
    expect(aFilters, [
      ['modified', '=', '2026-01-01 00:00:03'],
      ['name', '>', 'X-3'],
    ]);
    expect(phaseA['order_by'], 'name asc');
    // Every recorded call across both pages pinned limit_start to 0.
    for (final c in rec.calls) {
      expect(c['limit_start'], 0);
    }
  });

  // ── Two-phase page assembly (Phase A tie-drain + Phase B advance) ─────
  test('resume: two-phase keyset — Phase A tie-drain then Phase B advance, '
      'logical page = A ++ B', () async {
    final rec = _Recorder();
    final fetcher = PullPageFetcher(listHttp: rec.responder([[], []]));
    await fetcher.fetch(
      doctype: 'X',
      meta: _meta(),
      cursor: const Cursor(
        modified: '2026-05-01 12:00:00',
        name: 'M-100',
        complete: false,
      ),
      pageSize: 500,
    );
    expect(rec.calls.length, 2, reason: 'Phase A (empty) then Phase B');

    // Phase A: tie-drain within the same `modified` block, ordered by name.
    final a = rec.calls[0];
    expect((a['filters'] as List).cast<List>(), [
      ['modified', '=', '2026-05-01 12:00:00'],
      ['name', '>', 'M-100'],
    ]);
    expect(a['order_by'], 'name asc');
    expect(a['limit_start'], 0);
    expect(a['limit_page_length'], 500);

    // Phase B: advance past the block, ordered by (modified, name).
    final b = rec.calls[1];
    expect((b['filters'] as List).cast<List>(), [
      ['modified', '>', '2026-05-01 12:00:00'],
    ]);
    expect(b['order_by'], 'modified asc, name asc');
    expect(b['limit_start'], 0);
    expect(
      b['limit_page_length'],
      500,
      reason: 'Phase A returned 0 → Phase B may take the whole page',
    );
  });

  test('mid-tie boundary: Phase A drains part of a block by name, Phase B '
      'advances; combined = A ++ B with Phase B limit = pageSize - lenA',
      () async {
    final rec = _Recorder();
    final fetcher = PullPageFetcher(
      listHttp: rec.responder([
        // Phase A: two rows still inside the same-`modified` block.
        [
          {'name': 'M2-b', 'modified': '2026-05-01 12:00:02', 'v': 'b'},
          {'name': 'M2-c', 'modified': '2026-05-01 12:00:02', 'v': 'c'},
        ],
        // Phase B: three later-`modified` rows.
        [
          {'name': 'M3-a', 'modified': '2026-05-01 12:00:03', 'v': 'd'},
          {'name': 'M4-a', 'modified': '2026-05-01 12:00:04', 'v': 'e'},
          {'name': 'M5-a', 'modified': '2026-05-01 12:00:05', 'v': 'f'},
        ],
      ]),
    );
    final result = await fetcher.fetch(
      doctype: 'X',
      meta: _meta(),
      cursor: const Cursor(
        modified: '2026-05-01 12:00:02',
        name: 'M2-a',
        complete: false,
      ),
      pageSize: 5,
    );
    expect(rec.calls.length, 2);
    // Phase B was asked for exactly the remaining room.
    expect(rec.calls[1]['limit_page_length'], 3);
    // Combined page is A followed by B, in order.
    expect(result.rows.map((r) => r['name']).toList(),
        ['M2-b', 'M2-c', 'M3-a', 'M4-a', 'M5-a']);
    // Cursor advances to the LAST row of the logical page.
    expect(result.advancedCursor.modified, '2026-05-01 12:00:05');
    expect(result.advancedCursor.name, 'M5-a');
    expect(result.advancedCursor.complete, isFalse);
  });

  test('Phase-A-full page fires NO Phase B (large same-`modified` block '
      'drains one page at a time — no truncation)', () async {
    final rec = _Recorder();
    final fetcher = PullPageFetcher(
      listHttp: rec.responder([
        // Phase A fills the whole page → the block is not yet drained.
        [
          {'name': 'B-1', 'modified': '2026-05-01 12:00:02', 'v': '1'},
          {'name': 'B-2', 'modified': '2026-05-01 12:00:02', 'v': '2'},
        ],
      ]),
    );
    final result = await fetcher.fetch(
      doctype: 'X',
      meta: _meta(),
      cursor: const Cursor(
        modified: '2026-05-01 12:00:02',
        name: 'B-0',
        complete: false,
      ),
      pageSize: 2,
    );
    expect(rec.calls.length, 1,
        reason: 'Phase A filled the page → Phase B is skipped');
    // No request carried a `modified >` (advance) filter.
    for (final c in rec.calls) {
      final f = (c['filters'] as List?)?.cast<List>() ?? const [];
      expect(f.any((cl) => cl[0] == 'modified' && cl[1] == '>'), isFalse);
    }
    expect(result.rows.map((r) => r['name']).toList(), ['B-1', 'B-2']);
    // The cursor advances by name within the block → next fetch continues it.
    expect(result.advancedCursor.name, 'B-2');
    expect(result.advancedCursor.modified, '2026-05-01 12:00:02');
  });

  // ── Incremental seam (complete=true, seamRefetch) ─────────────────────
  test('incremental seam (seamRefetch=true): Phase A anchored at name > "" '
      're-pulls the WHOLE modified==m watermark block', () async {
    final rec = _Recorder();
    final fetcher = PullPageFetcher(listHttp: rec.responder([[], []]));
    await fetcher.fetch(
      doctype: 'X',
      meta: _meta(),
      cursor: const Cursor(
        modified: '2026-05-01 12:00:00',
        name: 'PRIOR-999',
        complete: true,
      ),
      pageSize: 500,
      seamRefetch: true,
    );
    final a = rec.calls[0];
    expect(
      (a['filters'] as List).cast<List>(),
      [
        ['modified', '=', '2026-05-01 12:00:00'],
        ['name', '>', ''],
      ],
      reason:
          'seam anchors at name > "" (NOT name > PRIOR-999) so the entire '
          'same-second block is re-pulled; the tie-skip / UPSERT drops the '
          'already-applied prefix',
    );
    expect(a['order_by'], 'name asc');
  });

  test('incremental (complete=true, pages 2+): advancedCursor = last row, '
      'complete bit preserved', () async {
    // Phase-aware fake: Phase A (tie-drain) empty, Phase B returns the delta.
    final fetcher = PullPageFetcher(
      listHttp: (doctype, params) async {
        final filters = (params['filters'] as List).cast<List>();
        final isPhaseB = filters.any((f) => f[0] == 'modified' && f[1] == '>');
        if (!isPhaseB) return const []; // Phase A: no ties
        return [
          {'name': 'X-1', 'modified': '2026-01-02 00:00:00', 'v': 'a'},
          {'name': 'X-2', 'modified': '2026-01-03 00:00:00', 'v': 'b'},
        ];
      },
    );
    final result = await fetcher.fetch(
      doctype: 'X',
      meta: _meta(),
      cursor: const Cursor(
        modified: '2026-01-01 00:00:00',
        name: 'A',
        complete: true,
      ),
      pageSize: 500,
    );
    expect(result.rows.length, 2, reason: 'A(0) ++ B(2)');
    expect(result.advancedCursor.name, 'X-2');
    expect(result.advancedCursor.modified, '2026-01-03 00:00:00');
    expect(result.advancedCursor.complete, isTrue,
        reason: 'incremental cursor keeps complete=true');
  });

  // ── Terminal / empty page ─────────────────────────────────────────────
  test('empty terminal page (both phases empty): rows empty, advancedCursor '
      'unchanged (loop terminator)', () async {
    final rec = _Recorder();
    final fetcher = PullPageFetcher(listHttp: rec.responder([[], []]));
    const start = Cursor(
      modified: '2026-01-01 00:00:00',
      name: 'A',
      complete: false,
    );
    final result = await fetcher.fetch(
      doctype: 'X',
      meta: _meta(),
      cursor: start,
      pageSize: 500,
    );
    expect(result.rows, isEmpty);
    expect(result.advancedCursor.name, 'A');
    expect(result.advancedCursor.modified, '2026-01-01 00:00:00');
    expect(result.advancedCursor.complete, isFalse);
  });

  // ── Field selection (unchanged) ───────────────────────────────────────
  test('skips layout fieldtypes but includes child-table fields', () async {
    final rec = _Recorder();
    final fetcher = PullPageFetcher(listHttp: rec.responder([[]]));
    final meta = DocTypeMeta(
      name: 'SO',
      fields: [
        DocField(fieldname: 'customer', fieldtype: 'Link', label: 'C', options: 'Customer'),
        DocField(fieldname: 'items', fieldtype: 'Table', label: 'I', options: 'Sales Order Item'),
        DocField(fieldname: 'taxes', fieldtype: 'Table MultiSelect', label: 'T', options: 'Tax'),
        DocField(fieldname: 'break1', fieldtype: 'Section Break', label: 'B'),
      ],
    );
    await fetcher.fetch(
      doctype: 'SO',
      meta: meta,
      cursor: Cursor.empty,
      pageSize: 500,
    );
    final fields = (rec.calls.single['fields'] as List).cast<String>();
    expect(fields, containsAll(['name', 'modified', 'customer']));
    expect(fields, isNot(contains('break1')));
    expect(fields, contains('items'));
    expect(fields, contains('taxes'));
  });
}
