import 'dart:convert';

import '../api/client.dart';
import '../database/app_database.dart';
import '../database/entities/link_option_entity.dart';
import '../models/doc_type_meta.dart';
import '../utils/depends_on_evaluator.dart';
import 'meta_service.dart';

const int _kLinkOptionCacheMaxEntries = 30;

/// Fetches link field options from API at runtime. Link filters are sent to the API; no DB table.
class LinkOptionService {
  final FrappeClient _client;
  final Map<String, List<LinkOptionEntity>> _memoryCache = {};
  final List<String> _cacheKeys = [];

  LinkOptionService(this._client);

  /// Cache of doctype -> title_field name, populated lazily from DB metadata.
  final Map<String, String?> _titleFieldCache = {};

  String _cacheKey(String doctype, List<List<dynamic>>? filters) {
    if (filters == null || filters.isEmpty) return doctype;
    return '$doctype|${filters.hashCode}';
  }

  void _putCache(String key, List<LinkOptionEntity> options) {
    if (_memoryCache.length >= _kLinkOptionCacheMaxEntries && !_memoryCache.containsKey(key)) {
      if (_cacheKeys.isNotEmpty) {
        final evict = _cacheKeys.removeAt(0);
        _memoryCache.remove(evict);
      }
    }
    if (!_memoryCache.containsKey(key)) _cacheKeys.add(key);
    _memoryCache[key] = options;
  }

  /// Fetches link options from API (with optional filters). No DB; filters sent to server.
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    bool forceRefresh = false,
    List<List<dynamic>>? filters,
  }) async {
    final normalizedFilters = _normalizeFiltersForDoctype(doctype, filters);
    final key = _cacheKey(doctype, normalizedFilters);
    if (!forceRefresh && _memoryCache.containsKey(key)) {
      return _memoryCache[key]!;
    }

    final meta = await _getDocTypeMeta(doctype);
    final titleField = _resolveTitleField(doctype, meta);

    List<dynamic> documents;

    try {
      // For child doctypes (istable=1), get_list/reportview only return
      // standard fields. Batch-fetch full docs via /api/resource instead.
      if (meta != null && meta.isTable) {
        documents = await _client.doctype.listChildDocs(
          doctype,
          filters: normalizedFilters,
          limitPageLength: 5000,
        );
      } else {
        documents = await _client.doctype.list(
          doctype,
          fields: ['*'],
          filters: normalizedFilters,
          limitPageLength: 5000,
        );
      }
    } catch (_) {
      return [];
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final linkOptions = <LinkOptionEntity>[];

    for (final doc in documents) {
      final docMap = doc is Map<String, dynamic> ? doc : null;
      if (docMap == null) continue;
      final name = docMap['name'] as String? ?? '';
      if (name.isEmpty) continue;
      String? label;

      // Determine the display label for the link option
      // First try the title field if it exists and has a value
      if (titleField != null &&
          docMap[titleField] != null &&
          docMap[titleField].toString().trim().isNotEmpty) {
        label = docMap[titleField].toString();
      }
      // Fall back to common label fields if title field is not available or empty
      for (final k in ['title', 'full_name', 'customer_name', 'supplier_name', 'label']) {
        if (label != null && label.isNotEmpty) break;
        if (docMap.containsKey(k) && docMap[k] != null) {
          label = docMap[k].toString();
          break;
        }
      }
      // Default to the document name if no label is found
      label ??= name;
      linkOptions.add(
        LinkOptionEntity(
          doctype: doctype,
          name: name,
          label: label,
          dataJson: jsonEncode(docMap),
          lastUpdated: now,
        ),
      );
    }

    _putCache(key, linkOptions);
    return linkOptions;
  }

  /// Normalize filter doctype to match the queried doctype.
  /// Fixes 417 "Field not permitted" when meta uses singular form (e.g. Village)
  /// but API queries plural (Villages).
  static List<List<dynamic>>? _normalizeFiltersForDoctype(
    String doctype,
    List<List<dynamic>>? filters,
  ) {
    if (filters == null || filters.isEmpty) return filters;
    final result = <List<dynamic>>[];
    for (final filter in filters) {
      if (filter.length < 4) continue;
      final filterDoctype = filter[0]?.toString();
      if (filterDoctype == null || filterDoctype.isEmpty) {
        result.add(List<dynamic>.from(filter));
        continue;
      }
      if (filterDoctype != doctype) {
        result.add([doctype, filter[1], filter[2], filter[3]]);
      } else {
        result.add(List<dynamic>.from(filter));
      }
    }
    return result.isEmpty ? null : result;
  }

  /// Returns field names that are dependencies in link_filters (eval:doc.xxx).
  /// Handles both `eval:doc.state` and `eval: doc.state` (Frappe standard format).
  /// e.g. [["District","state","=","eval: doc.state"]] -> ["state"]
  static List<String> getDependentFieldNames(String? linkFiltersJson) {
    if (linkFiltersJson == null || linkFiltersJson.isEmpty) return [];
    try {
      final decoded = jsonDecode(linkFiltersJson) as dynamic;
      final filters = decoded is List ? List<dynamic>.from(decoded) : <dynamic>[];
      final names = <String>[];
      for (final filter in filters) {
        if (filter is! List) continue;
        for (final elem in filter) {
          if (elem is! String) continue;
          // Prefer the evaluator helper (supports "eval: doc.x" and variations)
          final extracted = DependsOnEvaluator.extractEvalDocField(elem);
          final fieldName = extracted ??
              (elem.startsWith('eval:doc.') ? elem.substring(9).trim() : null);
          if (fieldName != null && fieldName.isNotEmpty) {
            if (!names.contains(fieldName)) names.add(fieldName);
          }
        }
      }
      return names;
    } catch (_) {
      return [];
    }
  }

  /// Parse Frappe link_filters and build API filters.
  /// Frappe format: [["District","state","=","eval: doc.state"]]
  /// Handles both `eval:doc.x` and `eval: doc.x` (Frappe standard format).
  /// API get_list accepts: [["DocType", "field", "operator", value]] (4 elements).
  static List<List<dynamic>>? parseLinkFilters(
    String? linkFiltersJson,
    Map<String, dynamic> formData,
  ) {
    if (linkFiltersJson == null || linkFiltersJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(linkFiltersJson) as dynamic;
      final filters = decoded is List ? List<dynamic>.from(decoded) : <dynamic>[];
      final result = <List<dynamic>>[];
      for (final filter in filters) {
        if (filter is! List || filter.length < 4) continue;
        dynamic value = filter[3];
        if (value is String) {
          final fieldName = DependsOnEvaluator.extractEvalDocField(value);
          if (fieldName != null) {
            value = formData[fieldName];
            if (value == null || value == '') continue;
          }
        }
        result.add([filter[0], filter[1], filter[2], value]);
      }
      return result.isEmpty ? null : result;
    } catch (_) {
      return null;
    }
  }

  void clearCache(String doctype) {
    for (final k in _memoryCache.keys.toList()) {
      if (k == doctype || k.startsWith('$doctype|')) {
        _memoryCache.remove(k);
        _cacheKeys.remove(k);
      }
    }
    _titleFieldCache.remove(doctype);
  }

  /// Resolves the display field for a doctype.
  /// Checks title_field first, then falls back to first search_field from meta
  /// (common for child doctypes where title_field is not set).
  String? _resolveTitleField(String doctype, DocTypeMeta? meta) {
    if (_titleFieldCache.containsKey(doctype)) {
      return _titleFieldCache[doctype];
    }
    final titleField = meta?.titleField;
    _titleFieldCache[doctype] = titleField;
    return titleField;
  }

  Future<DocTypeMeta?> _getDocTypeMeta(String doctype) async {
    try {
      final database = await AppDatabase.getInstance();
      final metaService = MetaService(_client, database);
      return await metaService.getMeta(doctype);
    } catch (_) {
      return null;
    }
  }

  void clearAllCache() {
    _memoryCache.clear();
    _cacheKeys.clear();
    _titleFieldCache.clear();
  }
}
