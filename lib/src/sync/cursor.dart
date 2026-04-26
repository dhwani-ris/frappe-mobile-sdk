/// Pagination cursor for offline-first pull.
///
/// Holds the `modified` timestamp + `name` of the last successfully-applied
/// row in a doctype, so the next page can resume strictly after it. A null
/// (`empty`) cursor means "first sync — no prior watermark."
class Cursor {
  final String? modified;
  final String? name;

  const Cursor({this.modified, this.name});

  static const Cursor empty = Cursor();

  bool get isNull => modified == null && name == null;

  Cursor advance({required String modified, required String name}) =>
      Cursor(modified: modified, name: name);

  Map<String, Object?>? toJson() {
    if (isNull) return null;
    return {'modified': modified, 'name': name};
  }

  factory Cursor.fromJson(Map<String, dynamic>? json) {
    if (json == null) return Cursor.empty;
    return Cursor(
      modified: json['modified'] as String?,
      name: json['name'] as String?,
    );
  }
}
