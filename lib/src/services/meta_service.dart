import 'dart:convert';
import '../api/client.dart';
import '../models/doc_type_meta.dart';
import '../database/app_database.dart';
import '../database/entities/doctype_meta_entity.dart';

/// Max doctypes kept in memory; oldest (LRU) evicted when exceeded.
const int _kMetaCacheMaxSize = 15;

/// Service for managing DocType metadata.
/// Loads only required meta; uses bounded in-memory cache and clears after use for performance.
class MetaService {
  final FrappeClient _client;
  final AppDatabase _database;
  final Map<String, DocTypeMeta> _metaCache = {};
  final List<String> _metaCacheOrder = [];

  MetaService(this._client, this._database);

  void _putInCache(String doctype, DocTypeMeta meta) {
    if (_metaCache.containsKey(doctype)) {
      _metaCacheOrder.remove(doctype);
    } else {
      while (_metaCache.length >= _kMetaCacheMaxSize &&
          _metaCacheOrder.isNotEmpty) {
        final evict = _metaCacheOrder.removeAt(0);
        _metaCache.remove(evict);
      }
    }
    _metaCache[doctype] = meta;
    _metaCacheOrder.add(doctype);
  }

  /// Fetches from server and saves to DB only (no in-memory cache). Use for prefetch.
  Future<void> fetchAndStoreInDb(String doctype) async {
    final metaData = await _fetchMetaFromServer(doctype);
    final entity = DoctypeMetaEntity(
      doctype: doctype,
      modified: metaData['modified']?.toString(),
      metaJson: jsonEncode(metaData),
    );
    await _database.doctypeMetaDao.insertDoctypeMeta(entity);
  }

  Future<Map<String, dynamic>> _fetchMetaFromServer(String doctype) async {
    final metaJson = await _client.doctype.getDocTypeMeta(doctype);
    Map<String, dynamic> metaData;
    if (metaJson.containsKey('docs') && metaJson['docs'] is List) {
      final docs = metaJson['docs'] as List;
      if (docs.isNotEmpty && docs[0] is Map<String, dynamic>) {
        metaData = docs[0] as Map<String, dynamic>;
      } else {
        metaData = metaJson;
      }
    } else if (metaJson.containsKey('message')) {
      final message = metaJson['message'];
      if (message is List && message.isNotEmpty) {
        metaData = message[0] as Map<String, dynamic>;
      } else if (message is Map<String, dynamic>) {
        metaData = message;
      } else {
        metaData = metaJson;
      }
    } else if (metaJson.containsKey('data')) {
      metaData = metaJson['data'] as Map<String, dynamic>;
    } else if (metaJson.containsKey('fields')) {
      metaData = metaJson;
    } else {
      metaData = metaJson;
    }
    if (!metaData.containsKey('fields') || metaData['fields'] is! List) {
      throw Exception(
        'Invalid metadata format: missing fields array. Response keys: ${metaData.keys.toList()}',
      );
    }
    return metaData;
  }

  /// Get metadata for a DocType. Loads only when required; uses bounded cache.
  /// Call [clearDocTypeCache] when leaving the screen to free memory.
  Future<DocTypeMeta> getMeta(
    String doctype, {
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _metaCache.containsKey(doctype)) {
      _metaCacheOrder.remove(doctype);
      _metaCacheOrder.add(doctype);
      return _metaCache[doctype]!;
    }

    if (!forceRefresh) {
      final entity = await _database.doctypeMetaDao.findByDoctype(doctype);
      if (entity != null) {
        final meta = DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
        _putInCache(doctype, meta);
        return meta;
      }
    }

    final metaData = await _fetchMetaFromServer(doctype);
    final meta = DocTypeMeta.fromJson(metaData);
    final entity = DoctypeMetaEntity(
      doctype: doctype,
      modified: metaData['modified']?.toString(),
      metaJson: jsonEncode(metaData),
    );
    await _database.doctypeMetaDao.insertDoctypeMeta(entity);
    _putInCache(doctype, meta);
    return meta;
  }

  /// Prefetch doctypes into DB only (no in-memory cache). Use instead of loading all into memory.
  Future<void> prefetchToDb(List<String> doctypes) async {
    for (final doctype in doctypes) {
      try {
        await fetchAndStoreInDb(doctype);
      } catch (_) {
        // skip failed doctypes
      }
    }
  }

  /// Get metadata for multiple Doctypes (each loads into bounded cache).
  Future<Map<String, DocTypeMeta>> getMetas(List<String> doctypes) async {
    final Map<String, DocTypeMeta> result = {};
    for (final doctype in doctypes) {
      try {
        result[doctype] = await getMeta(doctype);
      } catch (_) {}
    }
    return result;
  }

  void clearCache() {
    _metaCache.clear();
    _metaCacheOrder.clear();
  }

  /// Clear one DocType from cache. Call when leaving form/list to free memory.
  void clearDocTypeCache(String doctype) {
    _metaCache.remove(doctype);
    _metaCacheOrder.remove(doctype);
  }

  Future<void> deleteMeta(String doctype) async {
    await _database.doctypeMetaDao.deleteByDoctype(doctype);
    clearDocTypeCache(doctype);
  }
}
