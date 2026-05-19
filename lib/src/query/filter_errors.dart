/// The filter is malformed, references unknown columns, or uses an
/// operator that isn't part of the supported set. Caller bug.
class FilterParseError implements Exception {
  final String message;
  const FilterParseError(this.message);
  @override
  String toString() => 'FilterParseError: $message';
}

/// The filter shape is well-formed but uses a feature this version of
/// the SDK doesn't translate offline (e.g. cross-doctype child filters,
/// tree operators, `user.department`-style dynamic values). Spec §6.5.
class UnsupportedFilterError implements Exception {
  final String message;
  const UnsupportedFilterError(this.message);
  @override
  String toString() => 'UnsupportedFilterError: $message';
}
