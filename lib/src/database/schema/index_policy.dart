import '../../models/doc_type_meta.dart';
import '../../models/doc_field.dart';
import '../field_type_mapping.dart';

/// Returns the ordered list of column names to CREATE INDEX on, respecting
/// the per-doctype cap. Always starts with server_name, modified, sync_status.
/// Remaining slots filled by: title_field__norm, search_fields__norm (up to 2),
/// sort_field, then Link fields (ordered by linkEdgeCount desc, then insertion).
List<String> chooseIndexes(
  DocTypeMeta meta, {
  int maxIndexes = 7,
  Map<String, int>? linkEdgeCount,
}) {
  final chosen = <String>[
    'server_name',
    'modified',
    'sync_status',
  ];

  void add(String col) {
    if (chosen.length >= maxIndexes) return;
    if (!chosen.contains(col)) chosen.add(col);
  }

  if (meta.titleField != null) {
    final f = _fieldByName(meta, meta.titleField!);
    if (f != null && sqliteColumnTypeFor(f.fieldtype) == 'TEXT') {
      add('${meta.titleField}__norm');
    }
  }

  var searchAdded = 0;
  for (final sf in (meta.searchFields ?? const <String>[])) {
    if (searchAdded >= 2) break;
    final f = _fieldByName(meta, sf);
    if (f != null && sqliteColumnTypeFor(f.fieldtype) == 'TEXT') {
      add('${sf}__norm');
      searchAdded++;
    }
  }

  if (meta.sortField != null &&
      meta.sortField != 'modified' &&
      _fieldByName(meta, meta.sortField!) != null) {
    add(meta.sortField!);
  }

  final linkFields = meta.fields
      .where((f) => isLinkFieldType(f.fieldtype))
      .map((f) => f.fieldname)
      .whereType<String>()
      .toList();

  if (linkEdgeCount != null) {
    linkFields.sort((a, b) {
      final ca = linkEdgeCount[a] ?? 0;
      final cb = linkEdgeCount[b] ?? 0;
      return cb.compareTo(ca);
    });
  }

  for (final ln in linkFields) {
    add(ln);
  }

  return chosen;
}

DocField? _fieldByName(DocTypeMeta meta, String name) {
  for (final f in meta.fields) {
    if (f.fieldname == name) return f;
  }
  return null;
}
