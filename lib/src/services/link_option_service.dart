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
  Future<List<LinkOptionEntity>> fetchAndCacheLinkOptions(String doctype) async {
    try {
      final documents = await _client.doctype.list(doctype) as List<dynamic>;

      await _database.linkOptionDao.deleteByDoctype(doctype);

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

      if (linkOptions.isNotEmpty) {
        await _database.linkOptionDao.insertLinkOptions(linkOptions);
      }

      return linkOptions;
    } catch (e) {
      return await getCachedLinkOptions(doctype);
    }
  }

  /// Get link options (from cache or fetch if needed)
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    bool forceRefresh = false,
  }) async {
    final cached = await getCachedLinkOptions(doctype);

    if (cached.isEmpty || forceRefresh) {
      try {
        return await fetchAndCacheLinkOptions(doctype);
      } catch (e) {
        return cached;
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final oneHourAgo = now - (60 * 60 * 1000);
    final isStale = cached.isEmpty ||
        (cached.isNotEmpty && cached.first.lastUpdated < oneHourAgo);

    if (isStale) {
      fetchAndCacheLinkOptions(doctype).catchError((_) {
        return <LinkOptionEntity>[];
      });
    }

    return cached;
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
