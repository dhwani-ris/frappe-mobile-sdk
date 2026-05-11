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

/// One-page list fetch with cursor pagination. Spec §5.1.
///
/// Builds the Frappe `frappe.client.get_list` query with the cursor
/// predicate. The spec's true predicate is
/// `(modified > cursor.modified) OR (modified == cursor.modified AND
/// name > cursor.name)` — Frappe's REST `or_filters` cannot express the
/// nested AND-within-OR in a single request, so we approximate with
/// `modified >= cursor.modified` and rely on PullApply's
/// UPSERT-by-`server_name` idempotency to absorb the seam row(s).
///
/// **Stall hazard:** when many rows share the same `modified` second (e.g.
/// a bulk import on the server), `modified >= cursor.modified` keeps
/// returning the same page — `advancedCursor` equals the input cursor and
/// the loop never terminates. [PullEngine] owns a stall guard: it detects
/// when `advancedCursor.modified == scratch.modified && advancedCursor.name
/// == scratch.name` and breaks. Callers that drive this fetcher directly
/// must apply the same guard. Idempotent UPSERT keeps applied rows correct.
/// For the `>pageSize` same-second case, rows past the first page are
/// missed until the cursor moves forward; the spec's two-request variant
/// (one per OR branch) can close that gap as a follow-up.
class PullPageFetcher {
  final ListHttpFn listHttp;

  PullPageFetcher({required this.listHttp});

  Future<PullPageResult> fetch({
    required String doctype,
    required DocTypeMeta meta,
    required Cursor cursor,
    required int pageSize,
  }) async {
    final fields = _fieldsToRequest(meta);
    final params = <String, Object?>{
      'fields': fields,
      'order_by': 'modified asc, name asc',
      'limit_page_length': pageSize,
    };

    if (!cursor.isNull && cursor.modified != null) {
      // Plan-compliant single-predicate form: `modified >= cursor.modified`.
      // Combined with `order_by modified asc, name asc`, this returns:
      //   - the seam row(s) at modified == cursor.modified — idempotently
      //     re-applied by PullApply's UPSERT-by-server_name
      //   - all rows with modified > cursor.modified
      // No row is silently skipped (unlike the earlier `name > X AND
      // modified > X` form, which excluded later-modified earlier-named
      // rows).
      params['filters'] = <List<Object?>>[
        ['modified', '>=', cursor.modified],
      ];
    }

    final rows = await listHttp(doctype, params);
    if (rows.isEmpty) {
      return PullPageResult(rows: rows, advancedCursor: cursor);
    }
    final last = rows.last;
    final next = Cursor(
      modified: last['modified'] as String?,
      name: last['name'] as String?,
    );
    return PullPageResult(rows: rows, advancedCursor: next);
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
