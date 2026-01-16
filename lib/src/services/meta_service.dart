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

    // Fetch from server - matching frappe_huf implementation exactly
    try {
      // Use the SDK's doctype service to get metadata (same as frappe_huf)
      // This matches frappe_huf/lib/services/frappe_service.dart line 55
      final metaJson = await _client.doctype.getDocTypeMeta(doctype);
      
      // Debug: Print the raw response structure (same as frappe_huf)
      print('Raw metadata response keys: ${metaJson.keys.toList()}');
      
      // The response structure might vary, try to extract the actual meta (same as frappe_huf)
      Map<String, dynamic> metaData;
      
      // PRIORITY 1: Check 'docs' array first (this is what the server actually returns!)
      if (metaJson.containsKey('docs') && metaJson['docs'] is List) {
        final docs = metaJson['docs'] as List;
        if (docs.isNotEmpty && docs[0] is Map<String, dynamic>) {
          metaData = docs[0] as Map<String, dynamic>;
          print('Using metadata from docs array');
        } else {
          metaData = metaJson;
        }
      }
      // Check if it's wrapped in 'message' field (common in Frappe API)
      else if (metaJson.containsKey('message')) {
        final message = metaJson['message'];
        if (message is List && message.isNotEmpty) {
          // message is an array, get first element
          metaData = message[0] as Map<String, dynamic>;
        } else if (message is Map<String, dynamic>) {
          // message is the metadata directly
          metaData = message;
        } else {
          metaData = metaJson;
        }
      }
      // Check if it's wrapped in 'data' field
      else if (metaJson.containsKey('data')) {
        metaData = metaJson['data'] as Map<String, dynamic>;
      }
      // Direct metadata structure (has 'fields' array)
      else if (metaJson.containsKey('fields')) {
        metaData = metaJson;
      }
      // Fallback: use the response as-is
      else {
        metaData = metaJson;
      }
      
      // Debug: Print the extracted metadata structure (same as frappe_huf)
      print('Extracted metadata keys: ${metaData.keys.toList()}');
      print('Fields count: ${metaData['fields'] is List ? (metaData['fields'] as List).length : 'N/A'}');
      
      // Validate that we have fields before parsing
      if (!metaData.containsKey('fields') || metaData['fields'] is! List) {
        throw Exception('Invalid metadata format: missing fields array. Response keys: ${metaData.keys.toList()}');
      }
      
      final meta = DocTypeMeta.fromJson(metaData);
      
      // Cache in memory
      _metaCache[doctype] = meta;
      
      // Save to database
      final entity = DoctypeMetaEntity(
        doctype: doctype,
        modified: metaData['modified']?.toString(),
        metaJson: jsonEncode(metaData),
      );
      await _database.doctypeMetaDao.insertDoctypeMeta(entity);
      
      return meta;
    } catch (e) {
      print('Error fetching metadata: $e');
      
      // Check if it's a type casting error - the data might be valid but parsing failed
      final errorStr = e.toString();
      if (errorStr.contains('is not a subtype') || errorStr.contains('type cast')) {
        // Try to parse with more lenient type handling
        print('Type casting error detected, metadata might be valid but parsing failed');
        // The error happened during DocField parsing, but we might have valid data
        // Re-throw with more context
        throw Exception('Failed to parse metadata for $doctype due to type mismatch. The server returned data but field parsing failed. Error: $e');
      }
      
      // Don't try frappe.client.get_meta fallback since it doesn't exist on this server
      // The primary method getDocTypeMeta should work
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
        // Log error but continue with other doctypes
        print('Failed to fetch meta for $doctype: $e');
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
