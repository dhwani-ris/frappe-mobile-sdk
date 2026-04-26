import 'package:diacritic/diacritic.dart';

/// Normalize a text value for case-/accent-insensitive LIKE search.
/// Rules: lowercase → strip Latin diacritics → collapse whitespace → trim.
/// Devanagari/Indic scripts: no case transform; diacritics not stripped
/// beyond what NFKD would do (the diacritic package is Latin-focused).
///
/// For v1, consumer apps with heavy Indic text can override via
/// SDKConfig.normalizeForSearch.
String normalizeForSearch(String? value) {
  if (value == null) return '';
  final lower = value.toLowerCase();
  final stripped = removeDiacritics(lower);
  final collapsed = stripped.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed;
}
