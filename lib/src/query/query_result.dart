/// Where each row in a [QueryResult] came from. Drives observability —
/// the SyncStatusBar can show "12 from server, 3 local edits" — and the
/// list-screen "Unsynced" filter chip's count.
///
/// `local`: row has uncommitted local edits (`sync_status` IN dirty,
/// blocked, conflict, failed). `server`: row is in `synced` state and
/// reflects what's on Frappe.
enum RowOrigin { local, server }

/// Result of a single read against the offline store. `rows` are the
/// resolved + decorated maps (Link `__display` keys present); `hasMore`
/// is true iff `rows.length == requested pageSize` so the caller knows
/// to issue a follow-up page. Spec §6.1.
class QueryResult<T> {
  final List<T> rows;
  final bool hasMore;
  final int returnedCount;
  final Map<RowOrigin, int> originBreakdown;
  const QueryResult({
    required this.rows,
    required this.hasMore,
    required this.returnedCount,
    required this.originBreakdown,
  });

  static const empty = QueryResult<Map<String, dynamic>>(
    rows: [],
    hasMore: false,
    returnedCount: 0,
    originBreakdown: {},
  );

  /// Convenience factory that derives `hasMore` from
  /// `rows.length == pageSize` and `returnedCount` from `rows.length`.
  /// Used by [UnifiedResolver] to keep the offline-path and online-passthrough
  /// constructions in sync — a future change to the `hasMore` heuristic
  /// (e.g. trusting a server-supplied flag) applies to both at once.
  factory QueryResult.ofRows(
    List<T> rows,
    int pageSize,
    Map<RowOrigin, int> originBreakdown,
  ) {
    return QueryResult<T>(
      rows: rows,
      hasMore: rows.length == pageSize,
      returnedCount: rows.length,
      originBreakdown: originBreakdown,
    );
  }
}
