// Doctype name → SQLite table name normalization.
//
// Rule: lowercase, non-[a-z0-9] → '_', collapse consecutive '_',
//       strip leading/trailing '_', prefix with 'docs__'.
//
// This matches and slightly strengthens Frappe's own `frappe.scrub(text)`
// helper, which is `text.replace(' ', '_').replace('-', '_').lower()`. We
// additionally collapse any non-alphanumeric run to a single underscore
// (apostrophes, slashes, etc.) so SQLite identifiers are always safe — the
// original DocType name is preserved untouched in `doctype_meta.doctype`
// for API calls.
//
// Note: Frappe's server-side MariaDB tables use the `tab<DocTypeName>`
// pattern with original casing; we use a different prefix (`docs__`) and
// always-lowercase form because this is the local on-device mirror, not a
// drop-in for the server schema.

String normalizeDoctypeTableName(String doctype, {String prefix = 'docs__'}) {
  final trimmed = doctype.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(doctype, 'doctype', 'must be non-empty');
  }
  final body = trimmed
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  if (body.isEmpty) {
    throw ArgumentError.value(
      doctype,
      'doctype',
      'normalized to empty string',
    );
  }
  return '$prefix$body';
}
