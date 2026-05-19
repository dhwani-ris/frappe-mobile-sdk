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

/// One-page list fetch with dual-mode pagination. Spec §5.1.
///
/// **Initial sync** (`cursor.complete == false`): uses `limit_start` offset
/// pagination — no `modified` filter, `limit_start` advances by `pageSize`
/// each page. This guarantees the full dataset is fetched before the cursor
/// is committed, avoiding the seam-skip risk of applying `modified >=` while
/// new records can still land behind the advancing watermark.
///
/// **Incremental sync** (`cursor.complete == true`): uses the classic
/// `modified >= cursor.modified` predicate with `limit_start = 0`. Combined
/// with `order_by modified asc, name asc` this returns:
///   - the seam row(s) at `modified == cursor.modified` — idempotently
///     re-applied by PullApply's UPSERT-by-server_name
///   - all rows with `modified > cursor.modified`
///
/// **Stall hazard (incremental only):** when many rows share the same
/// `modified` second, `modified >= cursor.modified` keeps returning the same
/// page. [PullEngine] owns the stall guard for this case (it only fires for
/// `complete == true` pages). For initial sync the loop terminates on an
/// empty page, so no stall guard is needed.
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
      'limit_start': cursor.complete ? 0 : cursor.start,
    };

    if (cursor.complete && cursor.modified != null) {
      // Incremental: single-predicate form `modified >= cursor.modified`.
      // Seam row at cursor.modified is re-applied idempotently by PullApply.
      params['filters'] = <List<Object?>>[
        ['modified', '>=', cursor.modified],
      ];
    }
    // Initial sync (complete=false): no filter, offset advances via limit_start.

    final rows = await listHttp(doctype, params);
    if (rows.isEmpty) {
      return PullPageResult(rows: rows, advancedCursor: cursor);
    }
    final last = rows.last;

    final Cursor next;
    if (cursor.complete) {
      // Incremental: advance by last row's modified/name timestamp.
      next = Cursor(
        modified: last['modified'] as String?,
        name: last['name'] as String?,
        complete: true,
      );
    } else {
      // Initial sync: advance offset; track modified/name for the final cursor
      // that markComplete() will persist after the full drain.
      next = Cursor(
        modified: last['modified'] as String?,
        name: last['name'] as String?,
        complete: false,
        start: cursor.start + rows.length,
      );
    }
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
