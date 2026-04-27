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
}
