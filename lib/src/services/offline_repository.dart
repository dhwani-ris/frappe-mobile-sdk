import 'dart:convert';
import 'dart:developer' as developer;
import 'package:uuid/uuid.dart';
import '../database/app_database.dart';
import '../database/entities/document_entity.dart';
import '../database/schema/child_schema.dart';
import '../database/schema/parent_schema.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/document.dart';
import '../sync/pull_apply.dart';
import 'local_writer.dart';

/// Repository for offline document operations
class OfflineRepository {
  final AppDatabase _database;
  final LocalWriter? _localWriter;
  final Uuid _uuid = const Uuid();

  /// Cache: doctype → parsed meta. Avoids re-decoding `metaJson` on every
  /// pulled row. Cleared implicitly when the process restarts; the SDK's
  /// own meta refresh path replaces stale entries via [_clearMetaCache].
  final Map<String, DocTypeMeta> _metaCache = {};

  /// Per-doctype tables (`docs__<doctype>`) we've already verified exist
  /// in the local DB. Avoids a `PRAGMA` per row.
  final Set<String> _ensuredTables = <String>{};

  /// Per-parent child meta registry. Populated by
  /// [ensureSchemaForClosure] from the closure's `Table` / `Table
  /// MultiSelect` fields. Used by [_writeToPerDoctypeTable] so child rows
  /// in a pulled parent doc end up in their own `docs__<child>` table.
  final Map<String, Map<String, PullApplyChildInfo>> _childMetasByParent = {};

  /// [localWriter] — when provided, every save also mirrors the parent +
  /// child rows into the per-doctype `docs__<doctype>` tables so the
  /// offline read path ([UnifiedResolver]) sees newly-saved data
  /// immediately. Spec §3.2.
  OfflineRepository(this._database, {LocalWriter? localWriter})
      : _localWriter = localWriter;

  /// Drops the in-memory meta cache. Call this after a meta refresh so
  /// schema-bumping fields (new column, dropped Link) take effect on the
  /// next pull.
  void invalidateMetaCache() {
    _metaCache.clear();
    _ensuredTables.clear();
    _childMetasByParent.clear();
  }

  /// Doctype names whose meta has at least one Table / Table MultiSelect
  /// field. Used by SyncService to decide whether to fetch full docs
  /// (with children) instead of bare `frappe.client.get_list` rows.
  Set<String> doctypesWithChildren() => _childMetasByParent.keys.toSet();

  /// Eagerly creates per-doctype mirror tables for every doctype the
  /// closure visited — parents AND children — and registers the child
  /// metas so subsequent saves can populate child tables.
  ///
  /// Without this, [saveServerDocument] only created tables lazily on
  /// the first row it actually wrote, which means doctypes the user has
  /// 0 rows for had no offline schema at all (Link pickers + filter
  /// resolvers had nothing to read).
  Future<void> ensureSchemaForClosure({
    required Map<String, DocTypeMeta> metas,
    required Set<String> childDoctypes,
  }) async {
    final db = _database.rawDatabase;
    for (final entry in metas.entries) {
      final doctype = entry.key;
      final meta = entry.value;
      final tableName = normalizeDoctypeTableName(doctype);
      if (_ensuredTables.contains(tableName)) continue;

      final existing = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
        [tableName],
      );
      if (existing.isEmpty) {
        final isChild = childDoctypes.contains(doctype) || meta.isTable;
        final ddls = isChild
            ? buildChildSchemaDDL(meta, tableName: tableName)
            : buildParentSchemaDDL(meta, tableName: tableName);
        await db.transaction((txn) async {
          for (final stmt in ddls) {
            await txn.execute(stmt);
          }
        });
        try {
          await _database.doctypeMetaDao.setTableName(doctype, tableName);
        } catch (_) {
          // setTableName may not be available on older schemas; harmless.
        }
      }
      _ensuredTables.add(tableName);
      _metaCache[doctype] = meta;
    }

    // Build the parent → fieldname → child-meta registry. We do this in
    // a second pass so all child metas are in `metas` when we look them
    // up.
    for (final entry in metas.entries) {
      final doctype = entry.key;
      final meta = entry.value;
      if (childDoctypes.contains(doctype) || meta.isTable) continue;
      final byField = <String, PullApplyChildInfo>{};
      for (final f in meta.fields) {
        final fname = f.fieldname;
        final ftype = f.fieldtype;
        if (fname == null) continue;
        if (ftype != 'Table' && ftype != 'Table MultiSelect') continue;
        final childDoctype = f.options;
        if (childDoctype == null || childDoctype.isEmpty) continue;
        final childMeta = metas[childDoctype];
        if (childMeta == null) continue;
        byField[fname] = PullApplyChildInfo(childDoctype, childMeta);
      }
      if (byField.isNotEmpty) {
        _childMetasByParent[doctype] = byField;
      }
    }
  }

  /// Create a new document locally
  Future<Document> createDocument({
    required String doctype,
    required Map<String, dynamic> data,
  }) async {
    final rawUuid = data['mobile_uuid'] as String?;
    final mobileUuid =
        (rawUuid != null && rawUuid.isNotEmpty) ? rawUuid : _uuid.v4();
    final dataWithUuid = <String, dynamic>{...data, 'mobile_uuid': mobileUuid};
    final document = Document.create(
      doctype: doctype,
      data: dataWithUuid,
      localId: mobileUuid,
    );

    final entity = _documentToEntity(document);
    await _database.documentDao.insertDocument(entity);

    // Mirror to per-doctype tables (parent + split Table children) so the
    // offline read path sees the new doc immediately. Best-effort: legacy
    // `documents` row above is the source of truth for push.
    if (_localWriter != null) {
      try {
        await _localWriter.writeParent(
          parentDoctype: doctype,
          data: dataWithUuid,
        );
      } catch (_) {}
    }

    return document;
  }

  /// Get document by local ID
  Future<Document?> getDocumentByLocalId(String localId) async {
    final entity = await _database.documentDao.findByLocalId(localId);
    return entity != null ? _entityToDocument(entity) : null;
  }

  /// Get document by server ID
  Future<Document?> getDocumentByServerId(
    String serverId,
    String doctype,
  ) async {
    final entity = await _database.documentDao.findByServerId(
      serverId,
      doctype,
    );
    return entity != null ? _entityToDocument(entity) : null;
  }

  /// Fetches a single row from the per-doctype `docs__<doctype>` table
  /// by either `server_name` or `mobile_uuid`. Returns the raw column map
  /// (field names as keys) or null if the table doesn't exist or no row
  /// matches. Used by fetch_from to resolve linked documents offline.
  Future<Map<String, dynamic>?> getRowFromPerDoctypeTable(
    String doctype,
    String nameOrUuid,
  ) async {
    final tableName = normalizeDoctypeTableName(doctype);
    final db = _database.rawDatabase;
    final tableCheck = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [tableName],
    );
    if (tableCheck.isEmpty) return null;
    final rows = await db.query(
      tableName,
      where: 'server_name = ? OR mobile_uuid = ?',
      whereArgs: [nameOrUuid, nameOrUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  /// Get all documents for a DocType (excluding deleted)
  Future<List<Document>> getDocumentsByDoctype(String doctype) async {
    final entities = await _database.documentDao.findByDoctype(doctype);
    final documents = entities.map(_entityToDocument).toList();
    // Filter out deleted documents
    return documents.where((doc) => doc.status != 'deleted').toList();
  }

  /// Get documents by status
  Future<List<Document>> getDocumentsByStatus(String status) async {
    final entities = await _database.documentDao.findByStatus(status);
    return entities.map(_entityToDocument).toList();
  }

  /// Get dirty documents (need sync)
  Future<List<Document>> getDirtyDocuments() async {
    return await getDocumentsByStatus('dirty');
  }

  /// Get dirty documents for a specific DocType
  Future<List<Document>> getDirtyDocumentsByDoctype(String doctype) async {
    final entities = await _database.documentDao.findByDoctypeAndStatus(
      doctype,
      'dirty',
    );
    return entities.map(_entityToDocument).toList();
  }

  /// Update document
  Future<Document> updateDocument(Document document) async {
    final entity = _documentToEntity(document);
    await _database.documentDao.updateDocument(entity);
    return document;
  }

  /// Update document data
  Future<Document> updateDocumentData(
    String localId,
    Map<String, dynamic> data,
  ) async {
    final document = await getDocumentByLocalId(localId);
    if (document == null) {
      throw Exception('Document not found: $localId');
    }

    final updated = document.updateData(data);
    await updateDocument(updated);

    if (_localWriter != null) {
      try {
        await _localWriter.writeParent(
          parentDoctype: updated.doctype,
          data: {'mobile_uuid': updated.localId, ...data},
          serverName: updated.serverId,
        );
      } catch (_) {}
    }

    return updated;
  }

  /// Delete document (soft delete - marks as deleted)
  Future<Document> deleteDocument(String localId) async {
    final document = await getDocumentByLocalId(localId);
    if (document == null) {
      throw Exception('Document not found: $localId');
    }

    final deleted = document.markDeleted();
    await updateDocument(deleted);
    return deleted;
  }

  /// Hard delete document (permanently remove from database)
  Future<void> hardDeleteDocument(String localId) async {
    await _database.documentDao.deleteByLocalId(localId);
  }

  /// Save server document locally
  Future<Document> saveServerDocument({
    required String doctype,
    required String serverId,
    required Map<String, dynamic> data,
  }) async {
    // Check if already exists
    final existing = await getDocumentByServerId(serverId, doctype);
    final Document document;
    if (existing != null) {
      // Update existing
      document = existing.copyWith(
        serverId: serverId,
        data: data,
        status: 'clean',
        modified: DateTime.now().millisecondsSinceEpoch,
      );
      await updateDocument(document);
    } else {
      final localId = _uuid.v4();
      document = Document.fromServer(
        doctype: doctype,
        serverId: serverId,
        data: data,
        localId: localId,
      );
      final entity = _documentToEntity(document);
      await _database.documentDao.insertDocument(entity);
    }

    // If this server-confirm is the writeback for a row that was
    // originally created offline, the per-doctype table already has
    // a `mobile_uuid=<X>, server_name=null, sync_status='dirty'` row.
    // Promote it to `server_name=<serverId>, sync_status='synced'`
    // BEFORE the meta-driven mirror below — otherwise `_writeToPerDoctypeTable`
    // looks the row up by `server_name`, finds nothing, and inserts a
    // duplicate alongside the offline row. Spec §3.2.
    final priorMobileUuid = data['mobile_uuid'] as String?;
    if (_localWriter != null &&
        priorMobileUuid != null &&
        priorMobileUuid.isNotEmpty) {
      try {
        await _localWriter.markSynced(
          parentDoctype: doctype,
          mobileUuid: priorMobileUuid,
          serverName: serverId,
        );
      } catch (_) {}
    }

    // Mirror the row into the per-doctype `docs__<doctype>` table so
    // P5's UnifiedResolver/FilterParser can serve list screens, Link
    // pickers, and `fetch_from` directly from native columns. Spec §3.
    // Best-effort: the legacy `documents` write above is the source of
    // truth for now; if the per-doctype write fails (e.g. meta absent
    // because closure expansion couldn't reach this doctype), the
    // consumer still sees the legacy data.
    await _writeToPerDoctypeTable(doctype, data);

    return document;
  }

  Future<void> _writeToPerDoctypeTable(
    String doctype,
    Map<String, dynamic> data,
  ) async {
    try {
      final meta = await _loadMeta(doctype);
      if (meta == null) return;
      final tableName = normalizeDoctypeTableName(doctype);
      await _ensurePerDoctypeTable(doctype, tableName, meta);
      // If the closure didn't pre-register child metas for this parent
      // (e.g. returning user where `ensureSchemaForClosure` ran on the
      // previous launch only), lazily build the registry from cached
      // child metas in `doctype_meta`. Keeps child mirroring working
      // across app restarts without requiring re-login.
      final childMetas = await _resolveChildMetas(doctype, meta);
      await PullApply.applyPage(
        db: _database.rawDatabase,
        parentMeta: meta,
        parentTable: tableName,
        childMetasByFieldname: childMetas,
        rows: [data],
      );
    } catch (e, st) {
      // Mirror is best-effort — the legacy `documents` row is still the
      // source of truth. We log so silent data-loss bugs (like the
      // PK-collision the system-column overwrite caused) are visible
      // next time instead of vanishing into a swallowed catch.
      developer.log(
        'per-doctype mirror write failed for $doctype/${data['name']}: $e',
        name: 'OfflineRepository',
        error: e,
        stackTrace: st,
      );
    }
  }

  Future<DocTypeMeta?> _loadMeta(String doctype) async {
    final cached = _metaCache[doctype];
    if (cached != null) return cached;
    final raw = await _database.doctypeMetaDao.getMetaJson(doctype);
    if (raw == null || raw.isEmpty || raw == '{}') return null;
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      if (parsed.isEmpty) return null;
      final meta = DocTypeMeta.fromJson(parsed);
      _metaCache[doctype] = meta;
      return meta;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, PullApplyChildInfo>> _resolveChildMetas(
    String parentDoctype,
    DocTypeMeta parentMeta,
  ) async {
    final cached = _childMetasByParent[parentDoctype];
    if (cached != null) return cached;
    final byField = <String, PullApplyChildInfo>{};
    for (final f in parentMeta.fields) {
      final fname = f.fieldname;
      final ftype = f.fieldtype;
      if (fname == null) continue;
      if (ftype != 'Table' && ftype != 'Table MultiSelect') continue;
      final childDoctype = f.options;
      if (childDoctype == null || childDoctype.isEmpty) continue;
      final childMeta = await _loadMeta(childDoctype);
      if (childMeta == null) continue;
      // Make sure the child mirror table exists -- on returning users
      // it may not yet, since `ensureSchemaForClosure` only ran on the
      // first login.
      final childTable = normalizeDoctypeTableName(childDoctype);
      if (!_ensuredTables.contains(childTable)) {
        final db = _database.rawDatabase;
        final existing = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
          [childTable],
        );
        if (existing.isEmpty) {
          final ddls = buildChildSchemaDDL(childMeta, tableName: childTable);
          await db.transaction((txn) async {
            for (final stmt in ddls) {
              await txn.execute(stmt);
            }
          });
        }
        _ensuredTables.add(childTable);
      }
      byField[fname] = PullApplyChildInfo(childDoctype, childMeta);
    }
    if (byField.isNotEmpty) {
      _childMetasByParent[parentDoctype] = byField;
    }
    return byField;
  }

  Future<void> _ensurePerDoctypeTable(
    String doctype,
    String tableName,
    DocTypeMeta meta,
  ) async {
    if (_ensuredTables.contains(tableName)) return;
    final db = _database.rawDatabase;
    final existing = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
      [tableName],
    );
    if (existing.isEmpty) {
      final ddls = buildParentSchemaDDL(meta, tableName: tableName);
      await db.transaction((txn) async {
        for (final stmt in ddls) {
          await txn.execute(stmt);
        }
      });
      // Persist the table-name mapping so future code (UnifiedResolver
      // etc.) can route through DoctypeMetaDao.getTableName(...).
      try {
        await _database.doctypeMetaDao.setTableName(doctype, tableName);
      } catch (_) {
        // setTableName may not be available on older schemas; harmless.
      }
    }
    _ensuredTables.add(tableName);
  }

  /// Updates `server_name` in per-doctype tables after a successful push.
  ///
  /// [mobileUuid] is the parent's `mobile_uuid` / `localId`.
  /// [serverName] is the server-assigned `name` for the parent row.
  /// [serverData] is the full Frappe document returned by the server,
  /// including child table arrays with server-assigned `name` per row.
  Future<void> markPushed({
    required String doctype,
    required String mobileUuid,
    required String serverName,
    required Map<String, dynamic> serverData,
  }) async {
    if (_localWriter == null) return;

    // 1. Parent per-doctype table.
    try {
      await _localWriter.markSynced(
        parentDoctype: doctype,
        mobileUuid: mobileUuid,
        serverName: serverName,
      );
    } catch (_) {}

    // 2. Child per-doctype tables.
    final meta = await _loadMeta(doctype);
    if (meta == null) return;
    final db = _database.rawDatabase;

    for (final field in meta.fields) {
      final fname = field.fieldname;
      final ftype = field.fieldtype;
      if (fname == null) continue;
      if (ftype != 'Table' && ftype != 'Table MultiSelect') continue;
      final childDoctype = field.options;
      if (childDoctype == null || childDoctype.isEmpty) continue;

      final serverList = serverData[fname];
      if (serverList is! List || serverList.isEmpty) continue;

      final childTable = normalizeDoctypeTableName(childDoctype);
      final tableCheck = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [childTable],
      );
      if (tableCheck.isEmpty) continue;

      for (var idx = 0; idx < serverList.length; idx++) {
        final serverRow = serverList[idx];
        if (serverRow is! Map) continue;
        final childServerName = serverRow['name']?.toString();
        if (childServerName == null || childServerName.isEmpty) continue;

        // Try by mobile_uuid first (server echoes it when mobile_control is active).
        final childMobileUuid = serverRow['mobile_uuid']?.toString();
        bool updated = false;
        if (childMobileUuid != null && childMobileUuid.isNotEmpty) {
          try {
            final count = await db.update(
              childTable,
              {'server_name': childServerName},
              where: 'mobile_uuid = ?',
              whereArgs: [childMobileUuid],
            );
            updated = count > 0;
          } catch (_) {}
        }
        // Fallback: match by parent_uuid + parentfield + idx.
        if (!updated) {
          try {
            await db.update(
              childTable,
              {'server_name': childServerName},
              where: 'parent_uuid = ? AND parentfield = ? AND idx = ?',
              whereArgs: [mobileUuid, fname, idx],
            );
          } catch (_) {}
        }
      }
    }
  }

  /// Convert Document to Entity
  DocumentEntity _documentToEntity(Document document) {
    return DocumentEntity(
      localId: document.localId,
      doctype: document.doctype,
      serverId: document.serverId,
      dataJson: jsonEncode(document.data),
      status: document.status,
      modified: document.modified,
    );
  }

  /// Convert Entity to Document
  Document _entityToDocument(DocumentEntity entity) {
    return Document(
      localId: entity.localId,
      doctype: entity.doctype,
      serverId: entity.serverId,
      data: jsonDecode(entity.dataJson) as Map<String, dynamic>,
      status: entity.status,
      modified: entity.modified,
    );
  }
}
