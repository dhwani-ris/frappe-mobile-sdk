import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../api/client.dart';
import '../models/closure_result.dart';
import '../models/dep_graph.dart';
import '../models/doc_type_meta.dart';
import '../models/mobile_form_name.dart';
import '../database/app_database.dart';
import '../database/entities/doctype_meta_entity.dart';
import 'bulk_watermark_probe.dart';
import 'closure_builder.dart';
import 'dependency_graph_builder.dart';
import 'meta_differ.dart';
import 'meta_migration.dart';

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
      groupName: existing?.groupName,
      sortOrder: existing?.sortOrder,
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
      groupName: existing?.groupName,
      sortOrder: existing?.sortOrder,
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
        if (meta.doctype.isEmpty) continue;
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

  /// Returns doctype names marked as mobile form (from login response, stored in doctype_meta).
  Future<List<String>> getMobileFormDoctypeNames() async {
    final list = await _database.doctypeMetaDao.findMobileFormDoctypes();
    return list.map((e) => e.doctype).where((d) => d.isNotEmpty).toList();
  }

  /// Returns doctypes grouped by group name, ordered by server-defined sort order.
  ///
  /// Groups are ordered by the lowest sortOrder of any member.
  /// Doctypes with null or empty groupName are placed in an 'Other' bucket.
  /// Returns an empty map if no mobile forms are configured.
  Future<Map<String, List<String>>> getMobileFormGroups() async {
    final list = await _database.doctypeMetaDao.findMobileFormDoctypes();
    final groups = <String, List<String>>{};
    for (final entity in list) {
      final group = (entity.groupName?.isNotEmpty == true)
          ? entity.groupName!
          : 'Other';
      groups.putIfAbsent(group, () => []).add(entity.doctype);
    }
    return groups;
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
    // First, mark all existing mobile forms as false (loop 1)
    final allMetas = await _database.doctypeMetaDao.findAll();
    for (final meta in allMetas) {
      if (meta.isMobileForm) {
        final updatedMeta = DoctypeMetaEntity(
          doctype: meta.doctype,
          modified: meta.modified,
          serverModifiedAt: meta.serverModifiedAt,
          isMobileForm: false,
          metaJson: meta.metaJson,
          groupName: meta.groupName,
          sortOrder: meta.sortOrder,
        );
        await _database.doctypeMetaDao.updateDoctypeMeta(updatedMeta);
      }
    }

    // Now update/create entries for mobile forms (loop 2)
    final doctypesToSync = <String>[];

    for (int i = 0; i < mobileFormNames.length; i++) {
      final mfn = mobileFormNames[i];
      final doctype = mfn.mobileDoctype;
      if (doctype.isEmpty) continue;
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
          groupName: mfn.groupName,
          sortOrder: i,
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
          groupName: mfn.groupName,
          sortOrder: i,
        );
        await _database.doctypeMetaDao.insertDoctypeMeta(newMeta);
        doctypesToSync.add(doctype);
      }
    }

    return doctypesToSync;
  }

  /// Thin wrapper for testing purposes only.
  @visibleForTesting
  Future<List<String>> updateMobileFormDoctypesForTest(
    List<MobileFormName> mobileFormNames,
  ) => _updateMobileFormDoctypes(mobileFormNames);

  /// Fetches mobile configuration from server and resyncs doctype metadata.
  ///
  /// Calls `/api/v2/method/mobile_auth.configuration` to get updated mobile form list
  /// and syncs doctype metadata for any doctypes that have been updated or are new.
  ///
  /// Throws if not authenticated or API call fails.
  Future<void> resyncMobileConfiguration() async {
    try {
      // Guest endpoint: call without auth headers to avoid invalid-token 401
      // when a stale/expired token is still present in memory.
      final result = await _client.rest.getPublic(
        '/api/v2/method/mobile_auth.configuration',
      );

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

  // ─────────── P2: offline-first extensions ───────────

  /// Computes the closure of doctypes reachable from [entryPoints] via
  /// `Link` + `Table` + `Table MultiSelect` edges. Spec §3.2.
  ///
  /// [metaFetcher] is an optional injection seam used by tests; in
  /// production it defaults to [getMeta] which itself uses the in-memory
  /// LRU + DB cache + network fallback chain.
  Future<ClosureResult> closure(
    List<String> entryPoints, {
    MetaFetcher? metaFetcher,
  }) async {
    return ClosureBuilder.build(
      entryPoints: entryPoints,
      metaFetcher: metaFetcher ?? (dt) => getMeta(dt),
    );
  }

  /// Returns the latest server `modified` per doctype. If [probe] is
  /// supplied and detects the optional bulk endpoint, one round-trip is
  /// used; otherwise it falls back to per-doctype GETs.
  ///
  /// [watermarkFetcher] overrides the per-doctype fallback for tests.
  Future<Map<String, String?>> refreshWatermarks(
    List<String> doctypes, {
    BulkWatermarkProbe? probe,
    Future<String?> Function(String doctype)? watermarkFetcher,
  }) async {
    if (probe != null) {
      final detection = await probe.detect(candidates: doctypes);
      if (detection.available) {
        final rows = await probe.fetchWatermarks(doctypes);
        return {
          for (final r in rows)
            r['doctype'] as String: r['modified'] as String?,
        };
      }
    }
    final out = <String, String?>{};
    final fallback =
        watermarkFetcher ?? (dt) => _client.doctype.getDocTypeWatermark(dt);
    for (final dt in doctypes) {
      try {
        out[dt] = await fallback(dt);
      } catch (_) {
        out[dt] = null;
      }
    }
    return out;
  }

  /// For each doctype, compares local `meta_watermark` against the server
  /// `modified`. On mismatch: refetches the full meta, runs [MetaDiffer],
  /// applies the diff via [MetaMigration], and persists fresh meta_json,
  /// meta_watermark, and dep_graph_json. Spec §4.9.
  ///
  /// Each doctype is processed independently — a failure on one (network
  /// error fetching meta, malformed payload, ALTER TABLE conflict, …) does
  /// NOT abort the rest of the batch. Returns a [MetaUpdateResult]
  /// summarising successes and per-doctype failures so the caller can
  /// surface them to the user or retry later.
  Future<MetaUpdateResult> ensureUpToDate(
    List<String> doctypes, {
    BulkWatermarkProbe? probe,
    Future<String?> Function(String doctype)? watermarkFetcher,
    MetaFetcher? metaFetcher,
  }) async {
    final dao = _database.doctypeMetaDao;
    final fetchMeta = metaFetcher ?? (dt) => getMeta(dt, forceRefresh: true);
    final serverMarks = await refreshWatermarks(
      doctypes,
      probe: probe,
      watermarkFetcher: watermarkFetcher,
    );

    final updated = <String>[];
    final unchanged = <String>[];
    final failed = <String, String>{};

    for (final dt in doctypes) {
      try {
        final newMark = serverMarks[dt];
        if (newMark == null) {
          // No watermark = nothing to compare. Treat as "unchanged" rather
          // than silently failing — caller decides whether to retry.
          unchanged.add(dt);
          continue;
        }
        final localMark = await dao.getMetaWatermark(dt);
        if (localMark == newMark) {
          unchanged.add(dt);
          continue;
        }

        final fresh = await fetchMeta(dt);
        final oldJson = await dao.getMetaJson(dt);
        final old = (oldJson == null || oldJson.isEmpty || oldJson == '{}')
            ? DocTypeMeta(name: dt, fields: const [])
            : DocTypeMeta.fromJson(
                jsonDecode(oldJson) as Map<String, dynamic>,
              );

        final diff = MetaDiffer.diff(oldMeta: old, newMeta: fresh);
        if (!diff.isNoOp) {
          final tableName = await dao.getTableName(dt);
          if (tableName != null) {
            await MetaMigration.apply(
              _database.rawDatabase,
              diff,
              tableName: tableName,
            );
          }
        }
        await dao.upsertMetaJson(dt, jsonEncode(fresh.toJson()));
        await dao.setMetaWatermark(dt, newMark);
        final dg = DependencyGraphBuilder.buildOutgoing(fresh);
        await dao.setDepGraphJson(dt, jsonEncode(dg.toJson()));
        updated.add(dt);
      } catch (e) {
        failed[dt] = e.toString();
      }
    }

    return MetaUpdateResult(
      updated: updated,
      unchanged: unchanged,
      failed: failed,
    );
  }

  /// Reads the cached dep graph for a doctype, or null if none persisted yet.
  Future<DepGraph?> depGraphFor(String doctype) async {
    final raw = await _database.doctypeMetaDao.getDepGraphJson(doctype);
    if (raw == null) return null;
    return DepGraph.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Persists each per-doctype graph in [closure] onto
  /// `doctype_meta.dep_graph_json` so later phases (PullEngine, push tier
  /// computer) can read them without rebuilding from meta.
  Future<void> primeDepGraphs(ClosureResult closure) async {
    final dao = _database.doctypeMetaDao;
    for (final dt in closure.doctypes) {
      final g = closure.graph[dt];
      if (g == null) continue;
      await dao.setDepGraphJson(dt, jsonEncode(g.toJson()));
    }
  }
}

/// Outcome of a [MetaService.ensureUpToDate] call. Each doctype lands in
/// exactly one of the three buckets — `updated` (watermark advanced and
/// schema/meta refreshed), `unchanged` (already in sync or no server
/// watermark available), or `failed` (with the stringified error). Allows
/// the caller to surface partial results to the user without aborting the
/// rest of the batch on a single error.
class MetaUpdateResult {
  final List<String> updated;
  final List<String> unchanged;
  final Map<String, String> failed;

  const MetaUpdateResult({
    required this.updated,
    required this.unchanged,
    required this.failed,
  });

  bool get allSucceeded => failed.isEmpty;
}
