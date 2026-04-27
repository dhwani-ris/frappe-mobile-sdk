import 'doc_field.dart';

/// Result returned by a [LinkFilterBuilder].
///
/// `filters` is the Frappe-style filter list, e.g.
/// `[['DocType', 'field', '=', value]]`.
///
/// Semantics:
/// - `filters == null` → explicit opt-out of meta `linkFilters`; fetch all records.
/// - `filters == []` → normalized to null by [LinkOptionService.resolveFilters];
///   semantically identical to null.
///
/// Future fields (limit / orderBy / mergeWithMeta) can be added without
/// breaking existing callers — keep the constructor `const` and named-arg.
class LinkFilterResult {
  final List<List<dynamic>>? filters;
  const LinkFilterResult({this.filters});
}

/// Builds runtime filters for a link-option fetch.
///
/// - [field]: the [DocField] being fetched for.
/// - [fieldName]: guaranteed non-null field name (SDK caller guards).
/// - [rowData]: the enclosing FormBuilder's form data (may be a child row).
/// - [parentFormData]: the parent form's data. Equals [rowData] when not
///   inside a child row.
///
/// Return `null` to fall back to meta `linkFilters`.
typedef LinkFilterBuilder = LinkFilterResult? Function(
  DocField field,
  String fieldName,
  Map<String, dynamic> rowData,
  Map<String, dynamic> parentFormData,
);
