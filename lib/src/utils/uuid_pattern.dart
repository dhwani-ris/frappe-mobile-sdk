/// Detects whether a string looks like a v4 UUID (the format the SDK
/// hands out for `mobile_uuid`s). Frappe server names are *never* this
/// shape — their naming series produce values like `HSFM-2026-00042`,
/// hash-based 10-char tokens, or autoname-by-field strings. So a
/// trimmed, case-insensitive match against the canonical UUID pattern
/// is a safe proxy for "this string is a local identity, not a server
/// PK".
///
/// Use this to gate any code path that would otherwise call
/// `client.doctype.getByName(doctype, value)` on a Link/Dynamic Link
/// payload — fetching a UUID from the server is guaranteed to 500
/// (DoesNotExistError), and worse, the in-form retry-on-failure path
/// can wedge the form open with stale errors.
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// True when [value], trimmed, matches the canonical 8-4-4-4-12 hex UUID
/// shape. Returns false for null, empty, or any non-UUID string.
bool looksLikeMobileUuid(String? value) {
  if (value == null) return false;
  final trimmed = value.trim();
  if (trimmed.isEmpty) return false;
  return _uuidPattern.hasMatch(trimmed);
}
