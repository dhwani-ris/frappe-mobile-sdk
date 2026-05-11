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
class Cursor {
  final String? modified;
  final String? name;
  final bool complete;

  const Cursor({this.modified, this.name, this.complete = false});

  static const Cursor empty = Cursor();

  bool get isNull => modified == null && name == null;

  Cursor advance({
    required String modified,
    required String name,
    bool complete = false,
  }) => Cursor(modified: modified, name: name, complete: complete);

  /// Returns a copy with `complete: true` — used by the pull engine when
  /// a doctype drains to mark the cursor as eligible for INCREMENTAL
  /// (delta) pulls on the next call.
  Cursor markComplete() =>
      Cursor(modified: modified, name: name, complete: true);

  Map<String, Object?>? toJson() {
    if (isNull) return null;
    return {'modified': modified, 'name': name, 'complete': complete};
  }

  factory Cursor.fromJson(Map<String, dynamic>? json) {
    if (json == null) return Cursor.empty;
    return Cursor(
      modified: json['modified'] as String?,
      name: json['name'] as String?,
      complete: json['complete'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Cursor &&
          modified == other.modified &&
          name == other.name &&
          complete == other.complete;

  @override
  int get hashCode => Object.hash(modified, name, complete);
}
