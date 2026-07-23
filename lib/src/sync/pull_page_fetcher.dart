import '../database/field_type_mapping.dart';
import '../models/doc_type_meta.dart';
import 'cursor.dart';

typedef ListHttpFn =
    Future<List<Map<String, dynamic>>> Function(
      String doctype,
      Map<String, Object?> params,
    );

class PullPageResult {
  final List<Map<String, dynamic>> rows;

  /// Cursor advanced to the *last row of this page* — the next call should
  /// resume strictly after it. On empty pages, equals the input cursor.
  final Cursor advancedCursor;

  const PullPageResult({required this.rows, required this.advancedCursor});
}

/// One-page keyset fetch. Spec §5.1 + 2026-07-23 keyset-resume fix.
///
/// Every mode pages by a `(modified, name)` KEYSET — `limit_start` is only
/// ever `0`. This eliminates the deep-OFFSET scans (staging-measured
/// 501→991ms across depth 0→25k) that, stacked onto the constant-heavy
/// bulk-child POST, crossed the 30s client timeout on heavy first syncs and
/// restarted the pull from offset 0 forever.
///
/// The composite keyset predicate `(modified>m) OR (modified=m AND name>n)`
/// is NOT expressible in one `frappe.client.get_list` (`or_filters` is a flat
/// OR — it cannot nest `modified=m AND name>n`). So a logical page is fetched
/// in **two AND-only phases** (result-identical), given the resume anchor
/// `(m, n)`:
///
///   * **Phase A — tie-drain:** `filters=[['modified','=',m],['name','>',n]]`,
///     `order_by name asc`, `limit pageSize`. Strict forward progress by
///     `name` within the same-`modified` block.
///   * **Phase B — advance (only if Phase A returned < pageSize):**
///     `filters=[['modified','>',m]]`, `order_by modified asc, name asc`,
///     `limit pageSize - lenA`. The logical page is A followed by B.
///
/// Modes:
///   * **First page** (`cursor.modified == null` — INITIAL): unfiltered,
///     `order_by modified asc, name asc`, `limit pageSize`. Single request.
///   * **Resume** (`complete=false`, non-null `(m,n)`): two-phase keyset from
///     the persisted `(m, n)` — this is THE fix; the old path discarded the
///     cursor and restarted unfiltered at offset 0.
///   * **Incremental seam** (`complete=true`, [seamRefetch] true — page 1 of a
///     delta pull): Phase A anchored at `name > ''` re-pulls the WHOLE
///     `modified == m` watermark-second block (idempotent UPSERT absorbs the
///     re-applies), then Phase B pulls `modified > m`. This preserves today's
///     `modified >= watermark` seam semantics without the same-`modified`
///     stall/truncation. Incremental pages 2+ use the normal keyset advance
///     ([seamRefetch] false).
///
/// Migrated `modified` timestamps are unique (spike: largest tie-block = 1),
/// so Phase A usually returns 0 rows — but it is kept for correctness against
/// genuine ties, and `order_by modified asc, name asc` is used throughout so
/// the keyset is well-defined.
///
/// The advanced cursor after a non-empty page is always the LAST row's
/// `(modified, name)` with the input `complete` bit preserved. A non-empty
/// page therefore ALWAYS advances the cursor strictly forward — no stall
/// guard is required (see [PullEngine]).
class PullPageFetcher {
  final ListHttpFn listHttp;

  PullPageFetcher({required this.listHttp});

  Future<PullPageResult> fetch({
    required String doctype,
    required DocTypeMeta meta,
    required Cursor cursor,
    required int pageSize,
    bool seamRefetch = false,
  }) async {
    final fields = _fieldsToRequest(meta);

    // INITIAL first page: no anchor yet → unfiltered, single request.
    if (cursor.modified == null) {
      final rows = await listHttp(doctype, <String, Object?>{
        'fields': fields,
        'order_by': 'modified asc, name asc',
        'limit_page_length': pageSize,
        'limit_start': 0,
      });
      return _advance(rows, cursor, complete: cursor.complete);
    }

    // Keyset anchor. On the incremental seam page we anchor the tie-drain at
    // name > '' to re-pull the whole watermark-second block; otherwise we
    // resume strictly after the persisted (modified, name).
    final anchorModified = cursor.modified!;
    final anchorName = seamRefetch ? '' : (cursor.name ?? '');

    // Phase A — tie-drain within the same `modified` block.
    final phaseA = await listHttp(doctype, <String, Object?>{
      'fields': fields,
      'filters': <List<Object?>>[
        ['modified', '=', anchorModified],
        ['name', '>', anchorName],
      ],
      'order_by': 'name asc',
      'limit_page_length': pageSize,
      'limit_start': 0,
    });

    final combined = <Map<String, dynamic>>[...phaseA];

    // Phase B — advance past the block, only if Phase A left room. Skipping it
    // when Phase A filled the page keeps a large same-`modified` block draining
    // one page at a time across successive fetch() calls (no truncation).
    if (phaseA.length < pageSize) {
      final phaseB = await listHttp(doctype, <String, Object?>{
        'fields': fields,
        'filters': <List<Object?>>[
          ['modified', '>', anchorModified],
        ],
        'order_by': 'modified asc, name asc',
        'limit_page_length': pageSize - phaseA.length,
        'limit_start': 0,
      });
      combined.addAll(phaseB);
    }

    return _advance(combined, cursor, complete: cursor.complete);
  }

  /// Builds a [PullPageResult]: on an empty page the input cursor is returned
  /// unchanged (loop terminator); otherwise the cursor advances to the last
  /// row's `(modified, name)` with [complete] preserved.
  PullPageResult _advance(
    List<Map<String, dynamic>> rows,
    Cursor cursor, {
    required bool complete,
  }) {
    if (rows.isEmpty) {
      return PullPageResult(rows: rows, advancedCursor: cursor);
    }
    final last = rows.last;
    return PullPageResult(
      rows: rows,
      advancedCursor: Cursor(
        modified: last['modified'] as String?,
        name: last['name'] as String?,
        complete: complete,
      ),
    );
  }

  /// Fields to request from `frappe.client.get_list`. Always includes
  /// `name` + `modified` (system identifiers); plus every persisted
  /// fieldname (skipping layout/break/button types). Child-table fields
  /// are included so Frappe expands them inline.
  static List<String> _fieldsToRequest(DocTypeMeta meta) {
    final set = <String>{'name', 'modified'};
    for (final f in meta.fields) {
      final t = f.fieldtype;
      final n = f.fieldname;
      if (n == null) continue;
      if (t == 'Table' || t == 'Table MultiSelect') {
        set.add(n);
        continue;
      }
      if (sqliteColumnTypeFor(t) != null) set.add(n);
    }
    return set.toList();
  }
}
