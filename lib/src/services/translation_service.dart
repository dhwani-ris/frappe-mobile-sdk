import '../api/client.dart';

/// Fetches and caches Frappe translations (mobile_auth.get_translations).
/// Response shape: { "data": { "lang": "en", "translations": { "Source": "Translated" } } }
class TranslationService {
  final FrappeClient _client;

  /// In-memory cache: lang -> (source -> translated)
  final Map<String, Map<String, String>> _cache = {};

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
  /// Returns the translations map (source -> translated).
  Future<Map<String, String>> loadTranslations(String lang) async {
    try {
      final result = await _client.rest.get(
        '/api/v2/method/mobile_auth.get_translations',
        queryParams: {'lang': lang},
      );
      if (result is! Map<String, dynamic>) return {};
      final data = result['data'] as Map<String, dynamic>? ?? result;
      final raw = data['translations'] as Map<String, dynamic>?;
      if (raw == null) return {};
      final map = raw.map(
        (k, v) => MapEntry(k.toString(), v?.toString() ?? k.toString()),
      );
      _cache[lang] = map;
      return map;
    } catch (_) {
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
    String text = (map != null ? map[source] : null) ?? source;
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
