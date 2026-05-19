import 'package:diacritic/diacritic.dart';

/// Normalize a text value for case-/accent-insensitive LIKE search.
/// Rules: lowercase → strip Latin diacritics → strip Indic ZWJ
/// (U+200D) → collapse whitespace → trim. The ZWJ strip lets Devanagari
/// queries match whether the source text uses an explicit zero-width
/// joiner between half-forms or not (e.g. `क्‍ष` vs `क्ष`); without this
/// the two encodings hash to different `__norm` values and one of them
/// never matches.
///
/// Devanagari/Indic case is unchanged (no concept of upper/lower); other
/// diacritics aren't stripped beyond what NFKD would do (the diacritic
/// package is Latin-focused). Consumer apps with heavier Indic
/// normalization needs can override via `SDKConfig.normalizeForSearch`.
String normalizeForSearch(String? value) {
  if (value == null) return '';
  final lower = value.toLowerCase();
  final stripped = removeDiacritics(lower);
  // U+200D ZERO WIDTH JOINER — invisible character used in Indic scripts
  // to force ligature/half-form rendering. Strip before whitespace
  // collapse so otherwise-identical strings match in search.
  final dezwj = stripped.replaceAll('‍', '');
  final collapsed = dezwj.replaceAll(RegExp(r'\s+'), ' ').trim();
  return collapsed;
}
