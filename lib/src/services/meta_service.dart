import 'dart:convert';
import 'package:erpnext_sdk_flutter/erpnext_sdk_flutter.dart';
import '../models/doc_type_meta.dart';
import '../database/app_database.dart';
import '../database/entities/doctype_meta_entity.dart';

/// Service for managing DocType metadata
class MetaService {
  final ERPNextClient _client;
  final AppDatabase _database;
  final Map<String, DocTypeMeta> _metaCache = {};

  MetaService(this._client, this._database);

  /// Get metadata for a DocType (with caching)
  /// 
  /// First checks local database, then server if not found or outdated
  Future<DocTypeMeta> getMeta(String doctype, {bool forceRefresh = false}) async {
    // Check cache first
    if (!forceRefresh && _metaCache.containsKey(doctype)) {
      return _metaCache[doctype]!;
    }

    // Check local database
    if (!forceRefresh) {
      final entity = await _database.doctypeMetaDao.findByDoctype(doctype);
      if (entity != null) {
        final meta = DocTypeMeta.fromJson(jsonDecode(entity.metaJson));
        _metaCache[doctype] = meta;
        return meta;
      }
    }

    try {
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
        throw Exception('Invalid metadata format: missing fields array. Response keys: ${metaData.keys.toList()}');
      }
      
      final meta = DocTypeMeta.fromJson(metaData);
      
      _metaCache[doctype] = meta;
      
      final entity = DoctypeMetaEntity(
        doctype: doctype,
        modified: metaData['modified']?.toString(),
        metaJson: jsonEncode(metaData),
      );
      await _database.doctypeMetaDao.insertDoctypeMeta(entity);
      
      return meta;
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('is not a subtype') || errorStr.contains('type cast')) {
        throw Exception('Failed to parse metadata for $doctype due to type mismatch. The server returned data but field parsing failed. Error: $e');
      }
      
      throw Exception('Failed to fetch metadata for $doctype: $e');
    }
  }

  /// Get metadata for multiple Doctypes
  Future<Map<String, DocTypeMeta>> getMetas(List<String> doctypes) async {
    final Map<String, DocTypeMeta> result = {};
    
    for (final doctype in doctypes) {
      try {
        result[doctype] = await getMeta(doctype);
      } catch (e) {
        // Continue with other doctypes
      }
    }
    
    return result;
  }

  /// Clear metadata cache
  void clearCache() {
    _metaCache.clear();
  }

  /// Clear specific DocType from cache
  void clearDocTypeCache(String doctype) {
    _metaCache.remove(doctype);
  }

  /// Delete metadata from database
  Future<void> deleteMeta(String doctype) async {
    await _database.doctypeMetaDao.deleteByDoctype(doctype);
    _metaCache.remove(doctype);
  }
}
