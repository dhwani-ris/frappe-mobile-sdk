import 'package:flutter/foundation.dart';

import '../api/client.dart';

/// Fetches and caches Frappe translations (mobile_auth.get_translations).
/// Response shape: { "data": { "lang": "en", "translations": { "Source": "Translated" } } }
class TranslationService {
  final FrappeClient _client;

  /// In-memory cache: lang -> (source -> translated)
  final Map<String, Map<String, String>> _cache = {};

  /// Lowercased-source index: lang -> (source.toLowerCase() -> translated).
  /// Frappe's Translation table collates source_text case-INSENSITIVELY
  /// (MariaDB utf8mb4_general_ci), so 'HB value' and 'HB Value' are ONE
  /// row server-side — whichever casing seeded first owns source_text.
  /// An exact Dart map lookup then misses for every other casing the
  /// app uses. [translate] falls back to this index on exact-miss so
  /// lookup semantics match the server's collation.
  final Map<String, Map<String, String>> _ciCache = {};

  /// Current locale for [translate]. Default "en".
  String _currentLang = 'en';

  TranslationService(this._client);

  /// Current language code used for [translate].
  String get currentLang => _currentLang;

  /// Set language and optionally load translations for it.
  Future<void> setLocale(String lang) async {
    if (lang.isEmpty) return;
    _currentLang = lang;
    if (!_cache.containsKey(lang)) {
      await loadTranslations(lang);
    }
  }

  /// Fetch translations for [lang] from API and cache.
  /// Response format: { "data": { "langs": ["hr", "my"], "translations": { "hr": {...}, "my": {...} } } }
  /// Returns the translations map (source -> translated).
  Future<Map<String, String>> loadTranslations(String lang) async {
    try {
      final result = await _client.rest.get(
        '/api/v2/method/mobile_auth.get_translations',
        queryParams: {'lang': lang},
      );
      if (result is! Map<String, dynamic>) return {};
      final data = result['data'] as Map<String, dynamic>? ?? result;

      // New format: data.translations is a map of lang -> translation map
      final translationsMap = data['translations'] as Map<String, dynamic>?;
      if (translationsMap == null) return {};

      // Extract translations for the requested language
      final raw = translationsMap[lang] as Map<String, dynamic>?;
      if (raw == null) return {};

      final map = raw.map(
        (k, v) => MapEntry(k.toString(), v?.toString() ?? k.toString()),
      );
      _cache[lang] = map;
      _ciCache[lang] = {
        for (final e in map.entries) e.key.toLowerCase(): e.value,
      };
      return map;
    } catch (e, st) {
      debugPrint('TranslationService.loadTranslations($lang) failed — $e\n$st');
      return {};
    }
  }

  /// Get cached translations for [lang]. Empty if not loaded.
  Map<String, String> getCachedTranslations(String lang) {
    return Map.from(_cache[lang] ?? {});
  }

  /// Translate [source]. Uses [currentLang] cache. Replaces {0}, {1}, ... with [args].
  /// Returns source if no translation or not loaded.
  String translate(String source, [List<Object>? args]) {
    if (source.isEmpty) return source;
    final map = _cache[_currentLang];
    String text = (map != null ? map[source] : null) ??
        _ciCache[_currentLang]?[source.toLowerCase()] ??
        source;
    if (args != null && args.isNotEmpty) {
      for (var i = 0; i < args.length; i++) {
        text = text.replaceAll('{$i}', args[i].toString());
      }
    }
    return text;
  }

  /// Alias for [translate] (Frappe-style __).
  String call(String source, [List<Object>? args]) => translate(source, args);
}
