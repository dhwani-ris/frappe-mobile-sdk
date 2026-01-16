import 'dart:convert';
import '../api/client.dart';
import '../database/app_database.dart';
import '../database/entities/link_option_entity.dart';

/// Service for fetching and caching link field options
class LinkOptionService {
  final FrappeClient _client;
  final AppDatabase _database;

  LinkOptionService(this._client, this._database);

  /// Get cached link options for a DocType
  Future<List<LinkOptionEntity>> getCachedLinkOptions(String doctype) async {
    return await _database.linkOptionDao.findByDoctype(doctype);
  }

  /// Fetch and cache link options from server
  /// Note: When filters are provided, results are NOT cached (always fetch fresh)
  Future<List<LinkOptionEntity>> fetchAndCacheLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    try {
      // Fetch with filters from server
      final documents = await _client.doctype.list(
        doctype,
        filters: filters,
        limit_page_length: 1000, // Fetch more records for filtered results
      ) as List<dynamic>;

      // Only cache if no filters (unfiltered data can be cached)
      // Filtered data should always be fetched fresh
      if (filters == null || filters.isEmpty) {
        await _database.linkOptionDao.deleteByDoctype(doctype);
      }

      final linkOptions = <LinkOptionEntity>[];
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final doc in documents) {
        Map<String, dynamic> docMap;
        if (doc is Map<String, dynamic>) {
          docMap = doc;
        } else {
          continue;
        }
        
        final name = docMap['name'] as String? ?? '';
        if (name.isEmpty) continue;

        String? label;
        for (final key in ['title', 'full_name', 'customer_name', 'supplier_name', 'label']) {
          if (docMap.containsKey(key) && docMap[key] != null) {
            label = docMap[key].toString();
            break;
          }
        }
        label ??= name;

        final option = LinkOptionEntity(
          doctype: doctype,
          name: name,
          label: label,
          dataJson: jsonEncode(docMap),
          lastUpdated: now,
        );
        linkOptions.add(option);
      }

      // Only cache unfiltered results
      if ((filters == null || filters.isEmpty) && linkOptions.isNotEmpty) {
        await _database.linkOptionDao.insertLinkOptions(linkOptions);
      }

      return linkOptions;
    } catch (e) {
      // On error, return cached data (may be unfiltered, but better than nothing)
      return await getCachedLinkOptions(doctype);
    }
  }

  /// Get link options (from cache or fetch if needed)
  /// When filters are provided, always fetches fresh data from server
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    bool forceRefresh = false,
    List<List<dynamic>>? filters,
  }) async {
    // If filters are provided, always fetch fresh data from server
    // because cached data may not match the current filter criteria
    if (filters != null && filters.isNotEmpty) {
      try {
        return await fetchAndCacheLinkOptions(doctype, filters: filters);
      } catch (e) {
        // On error, try to filter cached data client-side as fallback
        final cached = await getCachedLinkOptions(doctype);
        return _filterCachedOptions(cached, filters);
      }
    }

    // No filters: use cache as before
    final cached = await getCachedLinkOptions(doctype);

    if (cached.isEmpty || forceRefresh) {
      try {
        return await fetchAndCacheLinkOptions(doctype, filters: filters);
      } catch (e) {
        return cached;
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final oneHourAgo = now - (60 * 60 * 1000);
    final isStale = cached.isEmpty ||
        (cached.isNotEmpty && cached.first.lastUpdated < oneHourAgo);

    if (isStale) {
      fetchAndCacheLinkOptions(doctype, filters: filters).catchError((_) {
        return <LinkOptionEntity>[];
      });
    }

    return cached;
  }
  
  /// Filter cached options client-side (fallback when server fetch fails)
  List<LinkOptionEntity> _filterCachedOptions(
    List<LinkOptionEntity> cached,
    List<List<dynamic>> filters,
  ) {
    if (cached.isEmpty || filters.isEmpty) return cached;
    
    return cached.where((option) {
      try {
        final dataJson = option.dataJson;
        if (dataJson == null) return false;
        
        final docData = jsonDecode(dataJson) as Map<String, dynamic>;
        
        // Check if option matches all filters
        for (final filter in filters) {
          if (filter.length < 4) continue;
          
          final field = filter[1] as String;
          final operator = filter[2] as String;
          final value = filter[3];
          
          final fieldValue = docData[field];
          
          // Apply filter logic
          bool matches = false;
          switch (operator) {
            case '=':
              matches = fieldValue == value;
              break;
            case '!=':
            case '<>':
              matches = fieldValue != value;
              break;
            case '>':
              matches = (fieldValue as num?) != null && (value as num?) != null && 
                       (fieldValue as num) > (value as num);
              break;
            case '<':
              matches = (fieldValue as num?) != null && (value as num?) != null && 
                       (fieldValue as num) < (value as num);
              break;
            case '>=':
              matches = (fieldValue as num?) != null && (value as num?) != null && 
                       (fieldValue as num) >= (value as num);
              break;
            case '<=':
              matches = (fieldValue as num?) != null && (value as num?) != null && 
                       (fieldValue as num) <= (value as num);
              break;
            case 'like':
            case 'LIKE':
              matches = fieldValue?.toString().toLowerCase().contains(value.toString().toLowerCase()) ?? false;
              break;
            case 'in':
            case 'IN':
              if (value is List) {
                matches = value.contains(fieldValue);
              }
              break;
            default:
              matches = fieldValue == value;
          }
          
          if (!matches) return false;
        }
        
        return true;
      } catch (e) {
        return false;
      }
    }).toList();
  }
  
  /// Parse link_filters JSON string and build filters from form data
  /// Format: [["DocType", "field", "=", "eval:doc.other_field"]]
  /// Supports multiple filters: [["District","state","=","eval:doc.state"],["District","active","=",1]]
  static List<List<dynamic>>? parseLinkFilters(
    String? linkFiltersJson,
    Map<String, dynamic> formData,
  ) {
    if (linkFiltersJson == null || linkFiltersJson.isEmpty) {
      return null;
    }
    
    try {
      final filters = jsonDecode(linkFiltersJson) as List<dynamic>;
      final result = <List<dynamic>>[];
      
      for (final filter in filters) {
        if (filter is List && filter.length >= 4) {
          // Filter format: [DocType, field, operator, value]
          final doctype = filter[0] as String;
          final field = filter[1] as String;
          final operator = filter[2] as String;
          dynamic value = filter[3];
          
          // Handle eval:doc.field expressions (e.g., "eval:doc.state")
          if (value is String && value.startsWith('eval:doc.')) {
            final fieldName = value.substring(9).trim();
            value = formData[fieldName];
            // Skip filter if dependent field has no value (allows all options)
            if (value == null || value == '') {
              continue;
            }
          }
          
          // Handle eval: expressions (e.g., "eval:doc.field1 + doc.field2")
          // For now, we only support simple eval:doc.fieldname
          // Complex expressions can be added later if needed
          
          result.add([doctype, field, operator, value]);
        }
      }
      
      return result.isEmpty ? null : result;
    } catch (e) {
      // Return null on parse error (invalid JSON)
      return null;
    }
  }

  /// Clear cache for a specific DocType
  Future<void> clearCache(String doctype) async {
    await _database.linkOptionDao.deleteByDoctype(doctype);
  }

  /// Clear all caches
  Future<void> clearAllCache() async {
    await _database.linkOptionDao.deleteAll();
  }
}
