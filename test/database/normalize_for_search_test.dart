import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/normalize_for_search.dart';

void main() {
  group('normalizeForSearch', () {
    test('lowercases ASCII', () {
      expect(normalizeForSearch('Hello WORLD'), 'hello world');
    });

    test('strips Latin diacritics', () {
      expect(normalizeForSearch('café'), 'cafe');
      expect(normalizeForSearch('naïve'), 'naive');
      expect(normalizeForSearch('Ankıt Jänglır'), 'ankit janglir');
    });

    test('collapses whitespace and trims', () {
      expect(normalizeForSearch('  spaced   out  '), 'spaced out');
    });

    test('returns empty string for null or empty', () {
      expect(normalizeForSearch(null), '');
      expect(normalizeForSearch(''), '');
      expect(normalizeForSearch('   '), '');
    });

    test('passes through Devanagari (no case; diacritics preserved)', () {
      expect(normalizeForSearch('नमस्ते'), 'नमस्ते');
    });

    test('mixed script', () {
      expect(normalizeForSearch('Café नमस्ते'), 'cafe नमस्ते');
    });
  });
}
