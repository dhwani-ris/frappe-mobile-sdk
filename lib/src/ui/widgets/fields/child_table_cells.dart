import '../../../models/doc_field.dart';
import '../../../models/doc_type_meta.dart';

/// Resolves a Link value to the linked document's title. Hosts inject this so
/// the widget layer never reaches for a service singleton.
typedef LinkTitleResolver =
    Future<String?> Function(String doctype, String name);

const List<String> _systemRowKeys = <String>[
  'name',
  'server_name',
  'owner',
  'creation',
  'modified',
  'modified_by',
  'docstatus',
  'idx',
  'doctype',
  'parent',
  'parentfield',
  'parenttype',
  'parent_doctype',
  'mobile_uuid',
  'parent_uuid',
  'sync_status',
  'sync_op',
  'local_modified',
  'push_base_payload',
];

/// True for bookkeeping columns a row must never title or tabulate from.
bool isChildSystemKey(String key) =>
    _systemRowKeys.contains(key) ||
    key.endsWith('__is_local') ||
    key.endsWith('__norm') ||
    key.endsWith('__display');

DocField? _childField(String fieldname, DocTypeMeta? meta) {
  if (meta == null) return null;
  for (final f in meta.fields) {
    if (f.fieldname == fieldname) return f;
  }
  return null;
}

/// Columns the child doctype declares for its grid.
///
/// `isDataField` admits Table and Table MultiSelect, whose values are Lists —
/// rendering one would print a raw collection into a cell, so both are
/// excluded explicitly.
List<DocField> childListViewFields(DocTypeMeta? meta) {
  if (meta == null) return const <DocField>[];
  return meta.fields
      .where(
        (f) =>
            f.inListView &&
            f.isDataField &&
            f.fieldtype != 'Table' &&
            f.fieldtype != 'Table MultiSelect' &&
            !f.hidden &&
            (f.fieldname ?? '').isNotEmpty &&
            !isChildSystemKey(f.fieldname!),
      )
      .toList(growable: false);
}

/// The field's label, falling back to its fieldname.
String childLabelFor(String fieldname, DocTypeMeta? meta) {
  final label = _childField(fieldname, meta)?.label;
  if (label != null && label.trim().isNotEmpty) return label.trim();
  return fieldname;
}

/// Display text for one cell. A Link cell stores the linked document's id, so
/// resolve it to that document's title; other types render their raw value.
/// Returns null for an empty or absent value so callers can skip it.
Future<String?> childCellText(
  String fieldname,
  dynamic value,
  DocTypeMeta? meta,
  LinkTitleResolver? resolveTitle,
) async {
  if (value == null || value.toString().isEmpty) return null;
  final f = _childField(fieldname, meta);
  if (f != null &&
      f.fieldtype == 'Link' &&
      f.options != null &&
      f.options!.isNotEmpty &&
      resolveTitle != null) {
    try {
      final title = await resolveTitle(f.options!, value.toString());
      if (title != null && title.trim().isNotEmpty) return title.trim();
    } catch (_) {
      // Fall through to the raw id: a title lookup failure must never blank a
      // cell that has a value.
    }
  }
  if (f != null && f.fieldtype == 'Check') {
    final v = value.toString().trim();
    return (v == '1' || v.toLowerCase() == 'true') ? 'Yes' : 'No';
  }
  if (f != null && (f.fieldtype == 'Date' || f.fieldtype == 'Datetime')) {
    // Raw ISO is not a value to put in front of an operator.
    final parsed = DateTime.tryParse(value.toString().trim());
    if (parsed != null) {
      final d = parsed.toLocal();
      final dd = d.day.toString().padLeft(2, '0');
      final mm = d.month.toString().padLeft(2, '0');
      return f.fieldtype == 'Date'
          ? '$dd/$mm/${d.year}'
          : '$dd/$mm/${d.year} '
              '${d.hour.toString().padLeft(2, '0')}:'
              '${d.minute.toString().padLeft(2, '0')}';
    }
  }
  if (f != null && (f.fieldtype == 'Attach' || f.fieldtype == 'Attach Image')) {
    // An Attach cell holds one of three literals: a server URL, a durable
    // absolute local path from an offline pick, or a `pending:<id>` marker.
    // None of them is text to show an operator — surface a filename.
    final raw = value.toString().trim();
    if (raw.startsWith('pending:')) return 'Attached (not yet synced)';
    final name = raw.split('?').first.split('/').last.trim();
    return name.isEmpty ? 'Attached' : name;
  }
  return value.toString();
}

/// Label/value pairs for [fields] on [row], Links resolved to their titles.
///
/// Every declared column is emitted, blank ones included — a grid renders an
/// empty cell rather than collapsing the column, and dropping it would hide
/// from the operator that the field exists at all. A numeric `0` is a real
/// value; only a null or absent cell falls back to the em dash.
Future<List<MapEntry<String, String>>> resolveChildListViewCells(
  Map<String, dynamic> row,
  DocTypeMeta? meta,
  List<DocField> fields,
  LinkTitleResolver? resolveTitle,
) async {
  final out = <MapEntry<String, String>>[];
  for (final f in fields) {
    final fn = f.fieldname;
    if (fn == null || fn.isEmpty) continue;
    final text = await childCellText(fn, row[fn], meta, resolveTitle);
    out.add(
      MapEntry(
        childLabelFor(fn, meta),
        (text == null || text.isEmpty) ? '—' : text,
      ),
    );
  }
  return out;
}

/// A human title for a child row.
///
/// Prefers the child doctype's declared `title_field`, then the conventional
/// name columns, then walks the doctype's own field order so a row titles from
/// its first real data field rather than an arbitrary storage column, then any
/// non-system row key, and finally its 1-based position.
Future<String> resolveChildRowTitle(
  Map<String, dynamic> row,
  DocTypeMeta? meta,
  int index,
  LinkTitleResolver? resolveTitle,
) async {
  // Declared title_field first, then the conventional name columns — these
  // are the ones a row is recognised by when a doctype declares no title_field
  // (and when metadata is unavailable entirely).
  final preferred = <String>[
    if ((meta?.titleField ?? '').isNotEmpty) meta!.titleField!,
    'item_name',
    'item_code',
  ];
  for (final k in preferred) {
    final t = await childCellText(k, row[k], meta, resolveTitle);
    if (t != null && t.isNotEmpty) return t;
  }
  if (meta != null) {
    for (final f in meta.fields) {
      final fn = f.fieldname;
      if (fn == null || fn.isEmpty) continue;
      if (!f.isDataField || f.hidden) continue;
      if (isChildSystemKey(fn)) continue;
      final t = await childCellText(fn, row[fn], meta, resolveTitle);
      if (t != null && t.isNotEmpty) return '${childLabelFor(fn, meta)}: $t';
    }
  }
  for (final key in row.keys) {
    if (isChildSystemKey(key)) continue;
    final t = await childCellText(key, row[key], meta, resolveTitle);
    if (t != null && t.isNotEmpty) return '${childLabelFor(key, meta)}: $t';
  }
  return 'Row #${index + 1}';
}
