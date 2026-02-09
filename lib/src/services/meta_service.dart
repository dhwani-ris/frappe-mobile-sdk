import 'dart:convert';
import '../api/client.dart';
import '../models/doc_type_meta.dart';
import '../models/mobile_form_name.dart';
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
    // Preserve existing serverModifiedAt and isMobileForm if exists
    final existing = await _database.doctypeMetaDao.findByDoctype(doctype);
    final entity = DoctypeMetaEntity(
      doctype: doctype,
      modified: metaData['modified']?.toString(),
      serverModifiedAt: existing?.serverModifiedAt,
      isMobileForm: existing?.isMobileForm ?? false,
      metaJson: jsonEncode(metaData),
    );
    // Check if exists, update if present, insert if new
    if (existing != null) {
      await _database.doctypeMetaDao.updateDoctypeMeta(entity);
    } else {
      await _database.doctypeMetaDao.insertDoctypeMeta(entity);
    }
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
    // Preserve existing serverModifiedAt and isMobileForm if exists
    final existing = await _database.doctypeMetaDao.findByDoctype(doctype);
    final entity = DoctypeMetaEntity(
      doctype: doctype,
      modified: metaData['modified']?.toString(),
      serverModifiedAt: existing?.serverModifiedAt,
      isMobileForm: existing?.isMobileForm ?? false,
      metaJson: jsonEncode(metaData),
    );
    if (existing != null) {
      await _database.doctypeMetaDao.updateDoctypeMeta(entity);
    } else {
      await _database.doctypeMetaDao.insertDoctypeMeta(entity);
    }
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

  /// Checks mobile form doctypes and syncs meta if timestamps are newer.
  ///
  /// Compares serverModifiedAt from doctype_meta table with stored modified
  /// timestamps. Syncs any doctypes that have newer timestamps or are missing.
  /// Only checks doctypes marked as isMobileForm = true.
  Future<void> checkAndSyncDoctypes() async {
    try {
      // Get all mobile form doctypes from doctype_meta table
      final mobileFormMetas = await _database.doctypeMetaDao
          .findMobileFormDoctypes();

      if (mobileFormMetas.isEmpty) {
        return; // No mobile form doctypes to sync
      }

      final doctypesToSync = <String>[];

      for (final meta in mobileFormMetas) {
        final serverModifiedAt = meta.serverModifiedAt;

        if (serverModifiedAt == null || serverModifiedAt.isEmpty) {
          // No timestamp, sync if missing metadata
          if (meta.metaJson.isEmpty) {
            doctypesToSync.add(meta.doctype);
          }
          continue;
        }

        // Compare serverModifiedAt with stored modified timestamp
        final storedModified = meta.modified;
        if (storedModified == null ||
            storedModified.isEmpty ||
            _isTimestampNewer(serverModifiedAt, storedModified)) {
          doctypesToSync.add(meta.doctype);
        }
      }

      // Sync all doctypes that need updating
      if (doctypesToSync.isNotEmpty) {
        for (final doctype in doctypesToSync) {
          try {
            await fetchAndStoreInDb(doctype);
          } catch (e) {
            // Skip failed doctypes, continue with others
            continue;
          }
        }
      }
    } catch (e) {
      // Silently fail - don't block app launch
      return;
    }
  }

  /// Prefetch metadata for all mobile form doctypes into DB.
  Future<void> prefetchMobileFormDoctypes() async {
    try {
      final mobileFormMetas = await _database.doctypeMetaDao
          .findMobileFormDoctypes();
      final mobileFormDoctypes = mobileFormMetas
          .map((meta) => meta.doctype)
          .toList();

      if (mobileFormDoctypes.isNotEmpty) {
        await prefetchToDb(mobileFormDoctypes);
      }
    } catch (e) {
      // Silently fail
      return;
    }
  }

  /// Sync all mobile form doctypes.
  Future<void> syncAllMobileFormDoctypes() async {
    try {
      final mobileFormMetas = await _database.doctypeMetaDao
          .findMobileFormDoctypes();
      final mobileFormDoctypes = mobileFormMetas
          .map((meta) => meta.doctype)
          .toList();

      if (mobileFormDoctypes.isNotEmpty) {
        for (final doctype in mobileFormDoctypes) {
          try {
            await fetchAndStoreInDb(doctype);
          } catch (e) {
            // Continue with other doctypes
            continue;
          }
        }
      }
    } catch (e) {
      // Silently fail
      return;
    }
  }

  /// Updates mobile form doctypes in database from mobile form names list.
  ///
  /// Marks all existing mobile forms as false, then updates/creates entries
  /// for the provided mobile form names. Returns list of doctypes that need syncing.
  Future<List<String>> _updateMobileFormDoctypes(
    List<MobileFormName> mobileFormNames,
  ) async {
    // First, mark all existing mobile forms as false
    final allMetas = await _database.doctypeMetaDao.findAll();
    for (final meta in allMetas) {
      if (meta.isMobileForm) {
        final updatedMeta = DoctypeMetaEntity(
          doctype: meta.doctype,
          modified: meta.modified,
          serverModifiedAt: meta.serverModifiedAt,
          isMobileForm: false,
          metaJson: meta.metaJson,
        );
        await _database.doctypeMetaDao.updateDoctypeMeta(updatedMeta);
      }
    }

    // Now update/create entries for mobile forms
    final doctypesToSync = <String>[];

    for (final mfn in mobileFormNames) {
      final doctype = mfn.mobileDoctype;
      final existing = await _database.doctypeMetaDao.findByDoctype(doctype);

      if (existing != null) {
        // Check if timestamp is newer
        final serverModifiedAt = mfn.doctypeMetaModifiedAt;
        final needsSync =
            serverModifiedAt != null &&
            serverModifiedAt.isNotEmpty &&
            (existing.serverModifiedAt == null ||
                existing.serverModifiedAt!.isEmpty ||
                _isTimestampNewer(
                  serverModifiedAt,
                  existing.serverModifiedAt!,
                ));

        // Update existing entry with mobile form info
        final updatedMeta = DoctypeMetaEntity(
          doctype: doctype,
          modified: existing.modified,
          serverModifiedAt: mfn.doctypeMetaModifiedAt,
          isMobileForm: true,
          metaJson: existing.metaJson,
        );
        await _database.doctypeMetaDao.updateDoctypeMeta(updatedMeta);

        // Add to sync list if timestamp is newer or metadata is missing
        if (needsSync ||
            existing.metaJson.isEmpty ||
            existing.metaJson == '{}') {
          doctypesToSync.add(doctype);
        }
      } else {
        // Create new entry with mobile form info (metaJson will be empty until fetched)
        final newMeta = DoctypeMetaEntity(
          doctype: doctype,
          modified: null,
          serverModifiedAt: mfn.doctypeMetaModifiedAt,
          isMobileForm: true,
          metaJson: '{}', // Empty until metadata is fetched
        );
        await _database.doctypeMetaDao.insertDoctypeMeta(newMeta);
        doctypesToSync.add(doctype);
      }
    }

    return doctypesToSync;
  }

  /// Fetches mobile configuration from server and resyncs doctype metadata.
  ///
  /// Calls `mobile_auth.configuration` API to get updated mobile form list
  /// and syncs doctype metadata for any doctypes that have been updated or are new.
  ///
  /// Throws if not authenticated or API call fails.
  Future<void> resyncMobileConfiguration() async {
    try {
      // Call mobile_auth.configuration API
      final result = await _client.rest.call('mobile_auth.configuration');

      // Parse response - response structure: {"data": [...]}
      final response = result is Map<String, dynamic>
          ? (result['data'] is List
                ? result['data']
                : result['message'] is List
                ? result['message']
                : [])
          : <dynamic>[];

      if (response.isEmpty) {
        return; // No mobile forms configured
      }

      // Parse mobile form names
      final mobileFormNames = (response as List)
          .map((json) => MobileFormName.fromJson(json as Map<String, dynamic>))
          .toList();

      if (mobileFormNames.isEmpty) {
        return;
      }

      // Update mobile form doctypes and get list of doctypes to sync
      final doctypesToSync = await _updateMobileFormDoctypes(mobileFormNames);

      // Sync all doctypes that need updating
      if (doctypesToSync.isNotEmpty) {
        for (final doctype in doctypesToSync) {
          try {
            await fetchAndStoreInDb(doctype);
          } catch (e) {
            // Skip failed doctypes, continue with others
            continue;
          }
        }
      }
    } catch (e) {
      // Re-throw to let caller handle errors
      if (e is Exception) rethrow;
      throw Exception('Failed to resync mobile configuration: $e');
    }
  }

  /// Compares two timestamp strings to check if first is newer than second.
  ///
  /// Handles formats like "2026-02-09 17:29:03" or ISO 8601.
  bool _isTimestampNewer(String timestamp1, String timestamp2) {
    try {
      final date1 = _parseTimestamp(timestamp1);
      final date2 = _parseTimestamp(timestamp2);
      if (date1 == null || date2 == null) return false;
      return date1.isAfter(date2);
    } catch (e) {
      return false;
    }
  }

  DateTime? _parseTimestamp(String timestamp) {
    try {
      // Try ISO 8601 format first
      if (timestamp.contains('T')) {
        return DateTime.parse(timestamp);
      }
      // Try "YYYY-MM-DD HH:MM:SS" format
      if (timestamp.contains(' ')) {
        return DateTime.parse(timestamp.replaceAll(' ', 'T'));
      }
      // Try just date
      return DateTime.parse(timestamp);
    } catch (e) {
      return null;
    }
  }
}
