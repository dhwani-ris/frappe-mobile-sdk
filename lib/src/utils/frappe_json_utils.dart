/// Frappe's REST API returns boolean fields as `int` (0/1), `bool`, or
/// `String` ('1'/'true'/'0') depending on the endpoint and DocType
/// definition. [parseBool] is the canonical coercion used by every model
/// `fromJson` factory that needs to interpret a Frappe-shaped boolean.
///
/// Returns [defaultValue] when [value] is null or any non-recognised type.
bool parseBool(dynamic value, {bool defaultValue = false}) {
  if (value == null) return defaultValue;
  if (value is bool) return value;
  if (value is int) return value == 1;
  if (value is String) {
    final lower = value.toLowerCase();
    return value == '1' || lower == 'true';
  }
  return defaultValue;
}
