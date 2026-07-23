/// Pagination cursor for offline-first pull.
///
/// Holds the `modified` timestamp + `name` of the last successfully-applied
/// row in a doctype, so the next page can resume strictly after it. A null
/// (`empty`) cursor means "first sync — no prior watermark."
///
/// `complete` is the load-bearing bit: when true, the doctype has finished
/// at least one full pull and subsequent calls are delta pulls (RESUME →
/// INCREMENTAL transition). Mirrors the format already written by
/// `SyncService._pullOneInternal` so both pull paths interoperate without
/// silently dropping the field on read/write roundtrips.
///
/// Cursor semantics (SIG-9 interoperable `{modified,name,complete}` JSON):
///   * `modified == null`               → INITIAL (no watermark, first page
///                                          fetched unfiltered).
///   * `modified != null, complete=F`   → RESUME point: the next page is a
///                                          keyset fetch strictly after
///                                          `(modified, name)`. `limit_start`
///                                          is NEVER used again.
///   * `modified != null, complete=T`   → INCREMENTAL (delta) watermark.
///
/// `start` is a LEGACY offset field. It is no longer written by [toJson] and
/// is no longer consulted by [PullPageFetcher] (which now pages by keyset, not
/// `limit_start` offset). It is still PARSED by [fromJson] so a device holding
/// an old offset-format cursor migrates cleanly: `complete=false` + non-null
/// `(modified, name)` is reinterpreted as a keyset resume point and the stale
/// offset is ignored.
class Cursor {
  final String? modified;
  final String? name;
  final bool complete;
  final int start;

  const Cursor({
    this.modified,
    this.name,
    this.complete = false,
    this.start = 0,
  });

  static const Cursor empty = Cursor();

  bool get isNull => modified == null && name == null;

  Cursor advance({
    required String modified,
    required String name,
    bool complete = false,
  }) => Cursor(modified: modified, name: name, complete: complete);

  /// Returns a copy with `complete: true` and `start: 0` — used by the pull
  /// engine when a doctype drains to mark it as eligible for INCREMENTAL
  /// (delta) pulls on the next call.
  Cursor markComplete() =>
      Cursor(modified: modified, name: name, complete: true, start: 0);

  Map<String, Object?>? toJson() {
    if (isNull) return null;
    // NOTE: `start` is intentionally NOT written. The keyset pager resumes
    // from `(modified, name)` + `complete`; persisting an offset would only
    // resurrect the deep-OFFSET behaviour this fix removed. Keep the on-disk
    // shape identical to SyncService's per-page journal (SIG-9).
    return {
      'modified': modified,
      'name': name,
      'complete': complete,
    };
  }

  factory Cursor.fromJson(Map<String, dynamic>? json) {
    if (json == null) return Cursor.empty;
    return Cursor(
      modified: json['modified'] as String?,
      name: json['name'] as String?,
      complete: json['complete'] == true,
      start: json['start'] as int? ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cursor &&
          modified == other.modified &&
          name == other.name &&
          complete == other.complete &&
          start == other.start;

  @override
  int get hashCode => Object.hash(modified, name, complete, start);
}
