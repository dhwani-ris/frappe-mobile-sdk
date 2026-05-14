/// Shared base for the two filter-related exception types so the
/// `final String message; toString() => '$ClassName: $message';` pattern
/// is declared once. Subclasses override only the class name in
/// [toString] (kept as the class name so existing log greps still work).
abstract class FilterException implements Exception {
  final String message;
  const FilterException(this.message);
}

/// The filter is malformed, references unknown columns, or uses an
/// operator that isn't part of the supported set. Caller bug.
class FilterParseError extends FilterException {
  const FilterParseError(super.message);
  @override
  String toString() => 'FilterParseError: $message';
}

/// The filter shape is well-formed but uses a feature this version of
/// the SDK doesn't translate offline (e.g. cross-doctype child filters,
/// tree operators, `user.department`-style dynamic values). Spec §6.5.
class UnsupportedFilterError extends FilterException {
  const UnsupportedFilterError(super.message);
  @override
  String toString() => 'UnsupportedFilterError: $message';
}
