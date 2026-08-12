import 'dart:convert';
import 'dart:developer' as developer;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../api/client.dart';
import '../database/app_database.dart';
import '../database/field_type_mapping.dart';
import '../database/schema/child_schema.dart';
import '../database/schema/parent_schema.dart';
import '../database/schema/system_columns.dart';
import '../database/sqlite_utils.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/document.dart';
import '../models/meta_diff.dart';
import '../models/offline_mode.dart';
import '../models/offline_mode_notifier.dart';
import '../database/daos/outbox_dao.dart';
import '../models/outbox_row.dart';
import '../sync/payload_serializer.dart';
import '../sync/pull_apply.dart';
import 'local_writer.dart';
import 'meta_migration.dart';
import '../utils/sdk_log.dart';

/// Repository for offline document operations
class OfflineRepository {
  final AppDatabase _database;
  final LocalWriter? _localWriter;
  final OfflineModeNotifier _modeNotifier;
  final FrappeClient? client;

  /// Resolves a doctype's meta when missing from the local DB. Wired to
  /// `MetaService.getMeta` in production: fetches from server and persists
  /// to `doctype_meta`. Used as a fallback in [_resolveChildMetas] so that
  /// a `pullSync` page racing ahead of the closure-expansion's child-meta
  /// fetch doesn't silently drop child rows. Optional — left null in tests
  /// or environments without a `MetaService`, in which case the old
  /// "skip the slot" behaviour is preserved.
  final Future<DocTypeMeta> Function(String doctype)? _metaFetcher;

  /// Live offline-mode value — see [SyncService.offlineMode] for the
  /// rationale. Reads through [_modeNotifier] so mid-session flips
  /// take effect at every gate site immediately.
  OfflineMode get offlineMode => _modeNotifier.value;
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
  /// MultiSelect` fields. Used by [applyServerDocument] so child rows
  /// in a pulled parent doc end up in their own `docs__<child>` table.
  final Map<String, Map<String, PullApplyChildInfo>> _childMetasByParent = {};

  /// [localWriter] — when provided, every save also mirrors the parent +
  /// child rows into the per-doctype `docs__<doctype>` tables so the
  /// offline read path ([UnifiedResolver]) sees newly-saved data
  /// immediately. Spec §3.2.
  OfflineRepository(
    this._database, {
    LocalWriter? localWriter,
    OfflineMode offlineMode = const OfflineMode(
      enabled: true,
      isPersisted: true,
    ),
    OfflineModeNotifier? offlineModeNotifier,
    this.client,
    Future<DocTypeMeta> Function(String doctype)? metaFetcher,
  }) : _localWriter = localWriter,
       _metaFetcher = metaFetcher,
       _modeNotifier = offlineModeNotifier ?? OfflineModeNotifier(offlineMode);

  /// Drops the in-memory meta cache. Call this after a meta refresh so
  /// schema-bumping fields (new column, dropped Link) take effect on the
  /// next pull.
  void invalidateMetaCache() {
    _metaCache.clear();
    _ensuredTables.clear();
    _childMetasByParent.clear();
  }

  /// Drops the in-memory meta state for a SINGLE [doctype] after its meta
  /// was re-fetched from the server (see [MetaService.onMetaRefreshed]).
  ///
  /// Without this, a mid-session meta refresh — e.g. a reconnect resync
  /// running `checkAndSyncDoctypes` / `resyncMobileConfiguration` after the
  /// cache was already warmed at boot — updates the DAO + MetaService LRU
  /// but leaves this repository's copy stale until logout. A subsequent
  /// [saveDocument] would then read the old schema via [_loadMeta] and
  /// silently drop any newly-added field. Evicting here forces the next
  /// [_loadMeta] to re-read the fresh meta from the DAO.
  ///
  /// Clears three mirrors keyed on this doctype:
  ///   * `_metaCache`        — so save/delete read fresh parent meta;
  ///   * `_childMetasByParent` — so a changed child-table set is rebuilt;
  ///   * `_ensuredTables`    — so the next closure pull re-reconciles the
  ///     table schema (the save path already self-heals via
  ///     [reconcileParentTableForMeta], but the pull path relies on this).
  ///
  /// NOTE: `_childMetasByParent` is keyed by the PARENT doctype, so refreshing
  /// a CHILD doctype alone does not evict the parent's cached child-meta set —
  /// it stays until the parent is refreshed. This only affects the pull path's
  /// [_resolveChildMetas] cache; the save path rebuilds child metas via
  /// [_loadMeta] (evicted above), so saves are unaffected.
  void invalidateMetaCacheFor(String doctype) {
    _metaCache.remove(doctype);
    _childMetasByParent.remove(doctype);
    _ensuredTables.remove(normalizeDoctypeTableName(doctype));
  }

  /// Doctype names whose meta has at least one Table / Table MultiSelect
  /// field. Used by SyncService to decide whether to fetch full docs
  /// (with children) instead of bare `frappe.client.get_list` rows.
  /// SIG-12: returns the union of in-memory `_childMetasByParent.keys`
  /// and the persisted `is_parent_with_children = 1` rows in
  /// `doctype_meta`. Merging both sources is required because:
  ///   * In-memory keys reflect what `ensureSchemaForClosure` /
  ///     `_resolveChildMetas` have already touched in THIS process —
  ///     including doctypes registered this session whose flag has not
  ///     yet been persisted at the moment the query runs.
  ///   * Persisted rows reflect everything written by ANY prior session,
  ///     including doctypes the current process has not yet touched
  ///     (the cold-start case SIG-12 was filed for).
  /// Preferring memory-only loses persisted state on a fresh process;
  /// preferring DB-only loses unpersisted in-flight registrations.
  Future<Set<String>> doctypesWithChildren() async {
    final out = <String>{..._childMetasByParent.keys};
    final rows = await _database.rawDatabase.rawQuery(
      'SELECT doctype FROM doctype_meta WHERE is_parent_with_children = 1',
    );
    for (final r in rows) {
      out.add(r['doctype'] as String);
    }
    return out;
  }

  /// Eagerly creates per-doctype mirror tables for every doctype the
  /// closure visited — parents AND children — and registers the child
  /// metas so subsequent saves can populate child tables.
  ///
  /// Without this, the lazy table-creation path inside [applyServerDocument]
  /// would only build tables for doctypes that actually had rows on the
  /// first pull — leaving 0-row doctypes without offline schema, so Link
  /// pickers and filter resolvers had nothing to read.
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

      // Per-iteration try/catch so any single doctype's CREATE / reconcile
      // failure doesn't abort the whole migration — closure may contain
      // dozens of doctypes; one bad meta (e.g. an unforeseen DDL edge
      // case) must not strand the rest without offline schema. On
      // failure, log and continue; the table stays out of `_ensuredTables`
      // / `_metaCache` so a later retry can re-attempt.
      try {
        final exists = await sqliteTableExists(db, tableName);
        final isChild = childDoctypes.contains(doctype) || meta.isTable;
        if (!exists) {
          final ddls = isChild
              ? buildChildSchemaDDL(meta, tableName: tableName)
              : buildParentSchemaDDL(meta, tableName: tableName);
          await _executeDDL(ddls);
          try {
            await _database.doctypeMetaDao.setTableName(doctype, tableName);
          } catch (e, st) {
            // setTableName may not be available on older schemas; harmless.
            developer.log(
              'OfflineRepository.ensureSchemaForClosure: setTableName($doctype) skipped — $e\n$st',
              name: 'OfflineRepository',
            );
          }
        } else if (!isChild) {
          // Heal an existing parent table whose meta has evolved (e.g. a new
          // title_field whose `__norm` column never got ALTER-added). Child
          // tables don't carry `__norm` columns, so skip them here.
          await _reconcileParentTableSchema(doctype, tableName, meta);
        }
        _ensuredTables.add(tableName);
        _metaCache[doctype] = meta;
      } catch (e, st) {
        developer.log(
          'OfflineRepository.ensureSchemaForClosure: $doctype skipped — $e\n$st',
          name: 'OfflineRepository',
        );
      }
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
        // SIG-12: persist the flag so doctypesWithChildren survives a
        // process restart even before ensureSchemaForClosure runs again.
        try {
          await _database.doctypeMetaDao.setIsParentWithChildren(doctype, true);
        } catch (e, st) {
          // setIsParentWithChildren may not be available on older schemas
          // (test fixtures that only seed v3 doctype_meta). Best-effort.
          developer.log(
            'OfflineRepository.ensureSchemaForClosure: setIsParentWithChildren($doctype) skipped — $e\n$st',
            name: 'OfflineRepository',
          );
        }
      }
    }
  }

  void _requireOnlineClient(String method) {
    if (client == null) {
      throw StateError(
        'OfflineRepository.$method: online mode requires a non-null '
        'FrappeClient. Pass `client:` to the constructor when '
        'offlineMode.enabled = false.',
      );
    }
  }

  /// Reconciles local state after a server-first save (`createDocument`
  /// or `updateDocument`) succeeded for an offline-created record.
  ///
  /// The contract is identity-preserving — the existing local row at
  /// [mobileUuid] becomes the server-known row at [serverName], without
  /// forking a second `docs__<doctype>` row:
  ///
  /// 1. Attaches [serverName] to the existing local row + flips its
  ///    `sync_status` to `synced` ([LocalWriter.markSynced]).
  /// 2. Cancels every collapsable outbox row (`pending`/`failed`/
  ///    `blocked`/`conflict`) for `(doctype, mobileUuid)`. The server
  ///    has the doc now, so a queued INSERT/UPDATE is no longer owed.
  /// 3. Applies the full server snapshot via [applyServerDocument] so
  ///    server-side defaults / formula columns / child-table
  ///    reconciliation land in the local mirror. Step 1 must happen
  ///    first because [PullApply] looks the row up by `server_name`
  ///    and bails on `dirty/failed/blocked/conflict` rows — flipping
  ///    `sync_status` to `synced` is what unblocks the upsert path.
  ///
  /// Used by `FormScreen._handleSubmit` on the server-first edit-save
  /// path so a previously-failed offline record's lineage stays intact.
  Future<void> reconcileServerSave({
    required String doctype,
    required String mobileUuid,
    required String serverName,
    required Map<String, dynamic> serverData,
  }) async {
    final writer = _localWriter;
    if (writer != null) {
      try {
        await writer.markSynced(
          parentDoctype: doctype,
          mobileUuid: mobileUuid,
          serverName: serverName,
        );
      } catch (e, st) {
        sdkLog(
          'OfflineRepository.reconcileServerSave: markSynced failed for '
          '$doctype/$mobileUuid → $serverName — $e\n$st',
        );
      }
    }
    try {
      await OutboxDao(
        _database.rawDatabase,
      ).cancelPendingFor(doctype: doctype, mobileUuid: mobileUuid);
    } catch (e, st) {
      sdkLog(
        'OfflineRepository.reconcileServerSave: outbox cancelPendingFor '
        'failed for $doctype/$mobileUuid — $e\n$st',
      );
    }
    await applyServerDocument(
      doctype: doctype,
      serverName: serverName,
      data: serverData,
    );
  }

  /// Outbox rows for a single document (matched by `mobile_uuid`),
  /// filtered to states the user can act on: `failed`, `blocked`,
  /// `conflict`, `paused`. `done`, `pending`, and `inFlight` are
  /// intentionally excluded — only stuck-and-needs-attention rows reach
  /// the UI.
  Future<List<OutboxRow>> getSyncErrorsForDoc({
    required String doctype,
    required String mobileUuid,
  }) async {
    final all = await OutboxDao(
      _database.rawDatabase,
    ).findByMobileUuid(doctype: doctype, mobileUuid: mobileUuid);
    return all
        .where(
          (r) =>
              r.state == OutboxState.failed ||
              r.state == OutboxState.blocked ||
              r.state == OutboxState.conflict ||
              r.state == OutboxState.paused,
        )
        .toList();
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
    if (!await sqliteTableExists(db, tableName)) return null;
    final rows = await db.query(
      tableName,
      where: 'server_name = ? OR mobile_uuid = ?',
      whereArgs: [nameOrUuid, nameOrUuid],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  /// Returns rows from `docs__<doctype>` whose `sync_status` indicates
  /// pending push work — `dirty` (offline insert/update), `deleted`
  /// (tombstoned), or the terminal error states `sync_error`/`sync_blocked`.
  ///
  /// When [doctype] is null, scans every doctype that has a registered
  /// `table_name` in `doctype_meta`. Short-circuits in online mode (the
  /// outbox is the canonical push queue and is itself empty in that mode).
  Future<List<Document>> getDirtyDocuments({String? doctype}) async {
    if (!offlineMode.enabled) return const [];
    final db = _database.rawDatabase;

    // Candidate doctype -> table_name. A single doctype is one entry; a full
    // scan takes the enrolled set from doctype_meta.
    final tableByDoctype = <String, String>{};
    if (doctype != null) {
      tableByDoctype[doctype] = normalizeDoctypeTableName(doctype);
    } else {
      try {
        final rows = await db.rawQuery(
          "SELECT doctype, table_name FROM doctype_meta "
          "WHERE table_name IS NOT NULL AND table_name != ''",
        );
        for (final r in rows) {
          final dt = r['doctype'] as String?;
          final tbl = (r['table_name'] as String?) ?? '';
          if (dt != null && tbl.isNotEmpty) tableByDoctype[dt] = tbl;
        }
      } on DatabaseException catch (e, st) {
        sdkLog(
          'OfflineRepository.getDirtyDocuments: doctype_meta scan failed '
          '— $e\n$st',
        );
        return const [];
      }
    }
    if (tableByDoctype.isEmpty) return const [];

    // ONE metadata round-trip: every table's name + CREATE DDL, read from
    // `sqlite_master` in a single query. B43 — this replaces the old
    // per-doctype table + column existence probes (two sequential DB
    // round-trips EACH, O(N) on the main isolate — the "Sync Data page slow"
    // cause). Existence is membership in this map;
    // `sync_status` presence is read straight from the CREATE DDL, so child /
    // link `docs__*` tables (which lack the column) are skipped WITHOUT ever
    // issuing a throwing query against them. Uses only `sqlite_master`, so it
    // stays portable across every SQLite version the app ships on.
    final ddlByTable = <String, String>{};
    try {
      final tables = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type = 'table'",
      );
      for (final t in tables) {
        final name = t['name'] as String?;
        if (name != null) ddlByTable[name] = (t['sql'] as String?) ?? '';
      }
    } on DatabaseException catch (e, st) {
      sdkLog(
        'OfflineRepository.getDirtyDocuments: sqlite_master scan failed '
        '— $e\n$st',
      );
      return const [];
    }

    // `\b` guards against false positives on a hypothetical `*_sync_status*`
    // column (`_` is a word char, so no boundary there).
    final syncStatusColumn = RegExp(r'\bsync_status\b');
    // `sync_status` alone is not a sound parent marker: it is absent from
    // `systemChildColumnNames`, and `child_schema.dart` emits every mappable
    // DocField as a column — so a CHILD doctype that happens to declare a field
    // literally named `sync_status` gets one, and would be misclassified as a
    // parent here (its rows then read back through `Document.fromResolverRow`
    // as if they were top-level documents). `parent_uuid` IS a child system
    // column and is never emitted on a parent, so requiring its absence makes
    // the test unambiguous in both directions.
    final parentUuidColumn = RegExp(r'\bparent_uuid\b');
    final out = <Document>[];
    for (final entry in tableByDoctype.entries) {
      final dt = entry.key;
      final tableName = entry.value;
      final ddl = ddlByTable[tableName];
      if (ddl == null) continue; // table absent
      if (!syncStatusColumn.hasMatch(ddl)) continue; // no sync_status column
      if (parentUuidColumn.hasMatch(ddl)) {
        continue; // child mirror, not a parent
      }
      try {
        final rows = await db.query(
          tableName,
          where:
              "sync_status IN "
              "('dirty', 'deleted', 'sync_error', 'sync_blocked')",
        );
        for (final r in rows) {
          out.add(Document.fromResolverRow(dt, r));
        }
      } on DatabaseException catch (e, st) {
        sdkLog(
          'OfflineRepository.getDirtyDocuments: query failed for $dt '
          '— $e\n$st',
        );
      }
    }
    return out;
  }

  // ===== Phase 4: Offline-first save surface =====

  /// Single offline-or-online save entry point. Returns `mobile_uuid`
  /// (offline) or the server name (online). Routes through
  /// [LocalWriter.writeParentInTxn] + [OutboxDao.recordSave] in one
  /// spanning transaction so docs__ + outbox stay consistent.
  Future<String> saveDocument({
    required String doctype,
    required Map<String, dynamic> data,
  }) async {
    if (!offlineMode.enabled) {
      _requireOnlineClient('saveDocument');
      // Online: HTTP only — no docs__ or outbox writes (Section 5,
      // "Online vs offline mode invariant").
      final hasServerName =
          data['name'] is String && (data['name'] as String).isNotEmpty;
      if (hasServerName) {
        final response = await client!.document.updateDocument(
          doctype,
          data['name'] as String,
          data,
        );
        return (response['name'] as String?) ?? data['name'] as String;
      }
      final response = await client!.document.createDocument(doctype, data);
      return (response['name'] as String?) ?? '';
    }

    if (_localWriter == null) {
      throw StateError(
        'OfflineRepository.saveDocument: offline mode requires localWriter',
      );
    }

    final rawUuid = data['mobile_uuid'] as String?;
    final mobileUuid = (rawUuid != null && rawUuid.isNotEmpty)
        ? rawUuid
        : _uuid.v4();
    final dataWithUuid = <String, dynamic>{...data, 'mobile_uuid': mobileUuid};

    // Pre-resolve metas and the existing row BEFORE opening the write txn.
    // Anything that queries via the outer Database while a txn is active
    // deadlocks (sqflite serializes ops through one queue, and the txn
    // holds it).
    final parentMeta = await _loadMeta(doctype);
    if (parentMeta == null) {
      // No local meta for this doctype — the form can't have rendered
      // without it, so it was never synced. Fail clean BEFORE opening the
      // write txn rather than letting LocalWriter resolve meta in-txn,
      // which would hang on the sqflite write queue.
      throw StateError(
        'OfflineRepository.saveDocument: no local meta for "$doctype" — '
        'sync the doctype before saving offline.',
      );
    }
    // Pre-resolve every child-table meta BEFORE the write txn — LocalWriter
    // never resolves meta in-txn (that would hang on the sqflite queue).
    // A child whose meta isn't synced locally is deliberately SKIPPED here
    // (its rows dropped, with a loud log) rather than resolved in-txn.
    // NOTE: a mid-sync race where a child's meta AND table are both still
    // absent (closure expansion vs. a save) drops those child rows; closing
    // that fully needs a pre-txn meta + table backfill and is out of scope
    // for this deadlock fix.
    final childMetasByDoctype = <String, DocTypeMeta>{};
    for (final f in parentMeta.fields) {
      final opt = f.options;
      if ((f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') &&
          opt != null &&
          opt.isNotEmpty) {
        final cm = await _loadMeta(opt);
        if (cm != null) {
          childMetasByDoctype[opt] = cm;
        } else {
          // Child meta not synced — skip its rows (loud log: child data is
          // dropped, critical for "child data went missing" reports).
          developer.log(
            'OfflineRepository.saveDocument: child meta missing for '
            '$opt (skipping child rows for this fieldtype)',
            name: 'OfflineRepository',
          );
        }
      }
    }

    final tableName = normalizeDoctypeTableName(doctype);

    // Heal parent-table schema drift BEFORE reading or writing the row.
    // If the cached meta has gained a field since this docs__ table was
    // created (e.g. a field added to the doctype server-side, picked up by
    // a later meta refresh), the INSERT below would reference a column the
    // table lacks and fail with "no such column". This mirrors the
    // self-heal PullEngine already performs via [reconcileParentTableForMeta]
    // before applying a pull page — the save path needs the same guard
    // because meta refresh and the boot-time `ensureSchemaForClosure` run
    // at different moments. No-ops when the table doesn't exist yet (the
    // INSERT path provisions it). MUST run outside the write txn below: it
    // does its own PRAGMA + ALTER on rawDatabase and would deadlock inside
    // a transaction.
    await reconcileParentTableForMeta(doctype, tableName, parentMeta);

    Map<String, Object?>? existing;
    try {
      final rows = await _database.rawDatabase.query(
        tableName,
        where: 'mobile_uuid = ?',
        whereArgs: [mobileUuid],
        limit: 1,
      );
      existing = rows.isEmpty ? null : rows.first;
    } on DatabaseException catch (e, st) {
      // Per-doctype table not provisioned yet — proceed with INSERT.
      sdkLog(
        'OfflineRepository.saveDocument: existing-row probe failed for '
        '$doctype/$mobileUuid (table likely missing) — $e\n$st',
      );
      existing = null;
    }

    final op = (existing == null || existing['server_name'] == null)
        ? OutboxOperation.insert
        : OutboxOperation.update;

    String? pushBase;
    if (existing != null) {
      final preserved = existing['push_base_payload'] as String?;
      if (preserved != null) {
        // Don't overwrite a base captured by an earlier edit (Invariant 6).
        pushBase = preserved;
      } else {
        pushBase = jsonEncode(
          PayloadSerializer.serializeForBase(existing, parentMeta),
        );
      }
    }

    final existingServerName = existing?['server_name'] as String?;

    // Carry Frappe's audit fields forward. LocalWriter's insert is
    // `ConflictAlgorithm.replace`, so any column it doesn't emit is reset to
    // NULL — and the form payload has no reason to round-trip `owner` /
    // `creation` / `modified_by`. Without this, editing a previously-pulled
    // doc would blank its `owner` and drop the row out of any `owner = <me>`
    // filtered list. Values come only from the row already on disk (i.e. from
    // the server, or from this device's own earlier save). Safe to read off
    // `existing` because `reconcileParentTableForMeta` above has already added
    // the columns.
    //
    // `modified_by` is deliberately EXCLUDED when the writer has a session
    // user: this save's author is the current user, not whoever last touched
    // the row, and carrying the stale value forward would win over the
    // writer's stamp (highest precedence is `data`). With no session user we
    // fall through to the old carry-forward so the on-disk value is preserved
    // exactly as before.
    final stampedBy = _localWriter.currentSessionUserId;
    for (final col in serverAuditColumnNames) {
      if (dataWithUuid.containsKey(col)) continue;
      if (col == 'modified_by' && stampedBy != null) continue;
      final v = existing?[col];
      if (v != null) dataWithUuid[col] = v;
    }

    await _database.rawDatabase.transaction((txn) async {
      await _localWriter.writeParentInTxn(
        txn: txn,
        parentDoctype: doctype,
        mobileUuid: mobileUuid,
        data: dataWithUuid,
        serverName: existingServerName,
        syncOp: op.wireName,
        pushBasePayload: pushBase,
        parentMeta: parentMeta,
        childMetasByDoctype: childMetasByDoctype,
      );

      await OutboxDao(
        txn,
      ).recordSave(doctype: doctype, mobileUuid: mobileUuid, operation: op);

      // docstatus transitions get their own outbox row, ordered after
      // the INSERT/UPDATE via a +1ms created_at bump.
      final docstatus = (data['docstatus'] is num)
          ? (data['docstatus'] as num).toInt()
          : null;
      if (docstatus == 1) {
        await OutboxDao(txn).recordSave(
          doctype: doctype,
          mobileUuid: mobileUuid,
          operation: OutboxOperation.submit,
          createdAt: DateTime.now().toUtc().add(
            const Duration(milliseconds: 1),
          ),
        );
      } else if (docstatus == 2) {
        await OutboxDao(txn).recordSave(
          doctype: doctype,
          mobileUuid: mobileUuid,
          operation: OutboxOperation.cancel,
          createdAt: DateTime.now().toUtc().add(
            const Duration(milliseconds: 1),
          ),
        );
      }
    });

    return mobileUuid;
  }

  /// Tombstones the docs__ row and enqueues a DELETE outbox row. If a
  /// pending INSERT existed (the doc never reached the server), cancels
  /// it and hard-deletes the docs__ row instead — there is nothing to
  /// push.
  /// True when a [DatabaseException] is the benign "the table/column was
  /// never created" case — e.g. a stale build site that never migrated a
  /// `docs__<child>` table (see the parent_uuid child-schema model). Those
  /// rows are unreachable garbage, so skipping them is safe. Any other
  /// DatabaseException (disk full, lock timeout, corruption) is a real
  /// failure and must propagate so the surrounding transaction rolls back.
  /// Mirrors the swallow-only-absence idiom in `MetaMigration.apply`.
  static bool _isBenignSchemaAbsence(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('no such table') || msg.contains('no such column');
  }

  /// Best-effort removal of the local `docs__` mirror (parent row, child
  /// rows, and any queued attachments) for a document that has already been
  /// deleted on the server. The server delete cannot be undone, so a local
  /// cleanup failure is logged, never thrown, and each table is attempted
  /// independently — the parent row is always removed even if a child table
  /// is absent (PR#36 round-4 B5). Callers: the online (`!offlineMode`)
  /// branch of [deleteDocument], and host UI that deletes via the API
  /// directly (e.g. FormScreen's online delete by serverId, which then calls
  /// this with the local mobile_uuid).
  Future<void> hardDeleteLocalMirror({
    required String doctype,
    required String mobileUuid,
  }) async {
    final db = _database.rawDatabase;
    Future<void> tryDelete(String table, String where) async {
      try {
        await db.delete(table, where: where, whereArgs: [mobileUuid]);
      } on DatabaseException catch (e, st) {
        sdkLog(
          'OfflineRepository.hardDeleteLocalMirror: $table cleanup failed '
          'for $doctype/$mobileUuid (best-effort) — $e\n$st',
        );
      }
    }

    await tryDelete('pending_attachments', 'top_parent_uuid = ?');
    await tryDelete(normalizeDoctypeTableName(doctype), 'mobile_uuid = ?');

    final parentMeta = await _loadMeta(doctype);
    if (parentMeta == null) return;
    for (final f in parentMeta.fields) {
      if (f.fieldtype != 'Table' && f.fieldtype != 'Table MultiSelect') {
        continue;
      }
      final childDoctype = f.options;
      if (childDoctype == null || childDoctype.isEmpty) continue;
      await tryDelete(
        normalizeDoctypeTableName(childDoctype),
        'parent_uuid = ?',
      );
    }
  }

  Future<void> deleteDocument({
    required String doctype,
    required String mobileUuid,
  }) async {
    if (!offlineMode.enabled) {
      _requireOnlineClient('deleteDocument');
      await client!.document.deleteDocument(doctype, mobileUuid);
      // Online saves still persist a local docs__ mirror (applyServerDocument
      // / reconcileServerSave). After the server delete succeeds, drop that
      // mirror so the doc doesn't reappear in list screens (PR#36 round-4 B5).
      await hardDeleteLocalMirror(doctype: doctype, mobileUuid: mobileUuid);
      return;
    }

    // Pre-load parent meta BEFORE opening the txn — `_loadMeta` queries
    // `doctype_meta` through the outer Database, which would deadlock
    // against our in-flight write txn.
    final parentMeta = await _loadMeta(doctype);

    await _database.rawDatabase.transaction((txn) async {
      final result = await OutboxDao(txn).recordSave(
        doctype: doctype,
        mobileUuid: mobileUuid,
        operation: OutboxOperation.delete,
      );

      final tableName = normalizeDoctypeTableName(doctype);
      if (result == RecordSaveResult.cancelledLocally) {
        // Pending INSERT cancelled; server never knew about this doc.
        // Any queued attachments are orphans — without this cleanup the
        // uploader would keep retrying against a top_parent_uuid that no
        // longer has a docs__ row (review minor #1).
        //
        // No `on DatabaseException catch` here: if attachment cleanup
        // fails the txn must roll back, otherwise we'd commit a
        // hard-deleted docs__ row alongside orphan pending_attachments
        // whose `top_parent_uuid` no longer resolves.
        await txn.delete(
          'pending_attachments',
          where: 'top_parent_uuid = ?',
          whereArgs: [mobileUuid],
        );
        try {
          await txn.delete(
            tableName,
            where: 'mobile_uuid = ?',
            whereArgs: [mobileUuid],
          );
          // Cascade-delete child rows (no FK, must be explicit).
          if (parentMeta != null) {
            for (final f in parentMeta.fields) {
              if (f.fieldtype != 'Table' &&
                  f.fieldtype != 'Table MultiSelect') {
                continue;
              }
              final childDoctype = f.options;
              if (childDoctype == null || childDoctype.isEmpty) continue;
              final childTable = normalizeDoctypeTableName(childDoctype);
              try {
                await txn.delete(
                  childTable,
                  where: 'parent_uuid = ?',
                  whereArgs: [mobileUuid],
                );
              } on DatabaseException catch (e, st) {
                // A real error must roll the whole delete back (don't commit
                // a parent delete with children left behind, reported as
                // success — PR#36 round-4 H8). Only a benignly absent child
                // table is skipped.
                if (!_isBenignSchemaAbsence(e)) rethrow;
                sdkLog(
                  'OfflineRepository.deleteDocument: child table absent for '
                  '$childDoctype (stale schema) — skipping cascade. $e\n$st',
                );
              }
            }
          }
        } on DatabaseException catch (e, st) {
          // Same policy as the child cascade above: a real error rolls the
          // delete back; only a benignly absent parent table is skipped.
          // (A child cascade rethrow also lands here — propagate it.)
          if (!_isBenignSchemaAbsence(e)) rethrow;
          sdkLog(
            'OfflineRepository.deleteDocument: parent table absent for '
            '$doctype/$mobileUuid (stale schema) — $e\n$st',
          );
        }
        return;
      }

      // Otherwise: tombstone the docs__ row. Sweep any queued
      // pending_attachments first — once the DELETE outbox row pushes,
      // the server-side doc is gone, so uploading attachments against
      // it would either fail (parent missing) or land orphan File rows
      // that the server then cascade-deletes. Cleaner to drop them now.
      await txn.delete(
        'pending_attachments',
        where: 'top_parent_uuid = ?',
        whereArgs: [mobileUuid],
      );
      try {
        await txn.update(
          tableName,
          {'sync_status': 'deleted', 'sync_op': 'DELETE'},
          where: 'mobile_uuid = ?',
          whereArgs: [mobileUuid],
        );
      } on DatabaseException catch (e, st) {
        sdkLog(
          'OfflineRepository.deleteDocument: tombstone update failed for '
          '$doctype/$mobileUuid — $e\n$st',
        );
      }
    });
  }

  /// Applies a server-pulled snapshot via PullApply (which respects
  /// local sync_status — dirty/failed/conflict/blocked/deleted rows are
  /// skipped). Single source of truth for "the server says this doc
  /// looks like X" — writes only to `docs__<doctype>`.
  Future<void> applyServerDocument({
    required String doctype,
    required String serverName,
    required Map<String, dynamic> data,
  }) async {
    await applyServerPage(doctype: doctype, rows: [data]);
  }

  /// Applies a page of server-pulled snapshots via PullApply.
  /// Used by SyncService to batch apply a whole page of data.
  Future<void> applyServerPage({
    required String doctype,
    required List<Map<String, dynamic>> rows,
    bool isInitialSync = false,
  }) async {
    if (rows.isEmpty) return;

    final meta = await _loadMeta(doctype);
    if (meta == null) {
      // Meta absent means the DocType schema was never synced — we cannot
      // write to a table whose columns we don't know. Throw so every caller
      // correctly classifies this as a failure (sync error counter, UI
      // error message) rather than silently skipping the apply and marking
      // the outbox row as done.
      throw StateError(
        'OfflineRepository.applyServerPage: meta missing for $doctype; '
        'cannot apply server snapshot for ${rows.length} rows',
      );
    }
    final tableName = normalizeDoctypeTableName(doctype);
    await _ensurePerDoctypeTable(doctype, tableName, meta);
    final childMetas = await _resolveChildMetas(doctype, meta);
    await PullApply.applyPage(
      db: _database.rawDatabase,
      parentMeta: meta,
      parentTable: tableName,
      childMetasByFieldname: childMetas,
      rows: rows,
      isInitialSync: isInitialSync,
    );
  }

  /// Runs a list of DDL statements inside a single SQLite transaction.
  /// Shared by [ensureSchemaForClosure], [_resolveChildMetas] (child-table
  /// fallback create), and [_ensurePerDoctypeTable] so any future change
  /// to DDL execution (retry, logging, savepoint wrapping) only needs to
  /// happen in one place.
  Future<void> _executeDDL(List<String> ddls) async {
    final db = _database.rawDatabase;
    await db.transaction((txn) async {
      for (final stmt in ddls) {
        await txn.execute(stmt);
      }
    });
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
    } catch (e, st) {
      developer.log(
        'OfflineRepository._loadMeta($doctype) parse failed — $e\n$st',
        name: 'OfflineRepository',
      );
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
      DocTypeMeta? childMeta = await _loadMeta(childDoctype);
      // Closure expansion fetches and persists every reachable child meta,
      // but `pullSync` can win the race against it: the user navigates to a
      // list whose `_pullDocuments` triggers a save before the parallel
      // `closure()` has gotten to the level that contains this child. When
      // that happens the DB read above misses and -- before this fallback --
      // every child row in the page was silently discarded. Routing through
      // the supplied [_metaFetcher] (`MetaService.getMeta` in production)
      // fetches the meta from the server and persists it, so subsequent
      // rows in the same page hit the in-memory cache.
      if (childMeta == null && _metaFetcher != null) {
        try {
          childMeta = await _metaFetcher(childDoctype);
          _metaCache[childDoctype] = childMeta;
        } catch (e, st) {
          // Network failure on the fallback fetch — fall through and skip
          // the slot. Better than crashing the entire pull.
          developer.log(
            'OfflineRepository._resolveChildMetas: _metaFetcher($childDoctype) failed — $e\n$st',
            name: 'OfflineRepository',
          );
        }
      }
      if (childMeta == null) continue;
      // Make sure the child mirror table exists -- on returning users
      // it may not yet, since `ensureSchemaForClosure` only ran on the
      // first login.
      final childTable = normalizeDoctypeTableName(childDoctype);
      if (!_ensuredTables.contains(childTable)) {
        final db = _database.rawDatabase;
        if (!await sqliteTableExists(db, childTable)) {
          await _executeDDL(
            buildChildSchemaDDL(childMeta, tableName: childTable),
          );
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
    if (!await sqliteTableExists(db, tableName)) {
      await _executeDDL(buildParentSchemaDDL(meta, tableName: tableName));
      // Persist the table-name mapping so future code (UnifiedResolver
      // etc.) can route through DoctypeMetaDao.getTableName(...).
      try {
        await _database.doctypeMetaDao.setTableName(doctype, tableName);
      } catch (e, st) {
        // setTableName may not be available on older schemas; harmless.
        developer.log(
          'OfflineRepository._ensurePerDoctypeTable: setTableName($doctype) skipped — $e\n$st',
          name: 'OfflineRepository',
        );
      }
    } else {
      await _reconcileParentTableSchema(doctype, tableName, meta);
    }
    _ensuredTables.add(tableName);
  }

  /// System columns the parent block emits — sourced from
  /// `database/schema/system_columns.dart` so DDL, form-save, pull-apply,
  /// and the meta-reconcile path all agree. A meta field that shares one of
  /// these names is dropped from the per-field loop, so we mustn't propose
  /// to ALTER ADD them either.
  static const _reconcileParentSystemCols = systemParentColumnNames;

  /// Heals an already-created `docs__<doctype>` parent table whose schema
  /// has drifted from the current meta — e.g. a `title_field` was added on
  /// the server after the table was first created, so the corresponding
  /// `<field>__norm` column is missing and PullApply's UPDATE fails. The
  /// SDK's persisted `metaJson` gets overwritten on every login meta
  /// refresh, so a json-vs-json `MetaDiffer.diff` will not flag this drift
  /// — we have to reconcile against the actual table columns.
  ///
  /// Only adds missing columns. Removed/renamed fields are left in place
  /// (SQLite's `DROP COLUMN` story is finicky and stale columns are
  /// harmless extras). The diff is funneled through [MetaMigration.apply]
  /// so existing-row backfill of new `__norm` columns happens for free.
  /// Public entrypoint for schema reconcile — called by [PullEngine]
  /// right before applying a pull page so the table's columns match the
  /// meta the apply step is about to use. Addresses the race where
  /// SNF's `runSnfPostSdkSync.ensureSchemaForClosure` and the SDK's
  /// concurrent `checkAndSyncDoctypes` read the meta cache at slightly
  /// different moments — SNF builds the table with meta-T1, PullApply
  /// then iterates meta-T2 (now refreshed) and crashes on
  /// `no such column`.
  ///
  /// No-op if the table doesn't exist yet — the create path runs
  /// elsewhere ([ensureSchemaForClosure] / [_ensurePerDoctypeTable]).
  /// Bypasses [_ensuredTables] on purpose so re-entrant callers (e.g.
  /// PullEngine running after [ensureSchemaForClosure] already added
  /// the table to the set) still get their migrations applied.
  Future<void> reconcileParentTableForMeta(
    String doctype,
    String tableName,
    DocTypeMeta meta,
  ) async {
    final db = _database.rawDatabase;
    if (!await sqliteTableExists(db, tableName)) return;
    await _reconcileParentTableSchema(doctype, tableName, meta);
  }

  Future<void> _reconcileParentTableSchema(
    String doctype,
    String tableName,
    DocTypeMeta meta,
  ) async {
    final db = _database.rawDatabase;
    final pragma = await db.rawQuery('PRAGMA table_info($tableName)');
    final actual = <String>{};
    for (final r in pragma) {
      final n = r['name'] as String?;
      if (n != null) actual.add(n);
    }
    if (actual.isEmpty) return;

    final normFields = meta.normFieldNames;

    final addedFields = <AddedField>[];
    final addedIsLocal = <String>[];
    final addedNorm = <String>[];
    final seen = <String>{..._reconcileParentSystemCols};

    // Backfill Frappe's server-owned audit columns onto tables created before
    // they were materialized. The loop below only ever proposes META-derived
    // columns (system names are pre-seeded into `seen` and therefore skipped),
    // so without this an already-installed app would keep a `docs__*` table
    // that has no `owner` / `creation` / `modified_by` — and `FilterParser`
    // now emits real SQL for those, which would fail with "no such column".
    //
    // `AppDatabase._migrateV5ToV6` covers the same gap at open time and is the
    // primary guarantee (it runs offline too); this is the per-doctype
    // belt-and-braces for tables created between an upgrade and this pull, and
    // for hosts that provision tables outside the migration path.
    //
    // ONLY nullable TEXT columns are safe to add this way: SQLite rejects
    // `ALTER TABLE ... ADD COLUMN ... NOT NULL` without a default, which is
    // why the other system columns (`local_modified`, `sync_status`, ...) are
    // deliberately NOT reconciled here.
    for (final col in serverAuditColumnNames) {
      if (actual.contains(col)) continue;
      addedFields.add(AddedField(name: col, sqlType: 'TEXT'));
    }

    for (final f in meta.fields) {
      final name = f.fieldname;
      final type = f.fieldtype;
      if (name == null) continue;
      if (!seen.add(name)) continue;
      final sqlType = sqliteColumnTypeFor(type);
      if (sqlType == null) continue;

      if (!actual.contains(name)) {
        addedFields.add(AddedField(name: name, sqlType: sqlType));
      }
      if (isLinkFieldType(type) && !actual.contains('${name}__is_local')) {
        addedIsLocal.add(name);
      }
      if (normFields.contains(name) &&
          sqlType == 'TEXT' &&
          !actual.contains('${name}__norm')) {
        addedNorm.add(name);
      }
    }

    if (addedFields.isEmpty && addedIsLocal.isEmpty && addedNorm.isEmpty) {
      // `owner` is necessarily already present on this branch — a missing audit
      // column would have landed in `addedFields` — but the guard keeps the
      // statement from ever running against a table without the column.
      if (actual.contains('owner')) await _ensureOwnerIndex(tableName);
      return;
    }

    final diff = MetaDiff(
      doctype: doctype,
      addedFields: addedFields,
      removedFields: const [],
      typeChanged: const [],
      addedIsLocalFor: addedIsLocal,
      addedNormFor: addedNorm,
      indexesToDrop: const [],
    );

    try {
      await MetaMigration.apply(db, diff, tableName: tableName);
      // After the ALTER, never before: a failed ALTER must not leave a
      // CREATE INDEX running against a missing column, and any index failure is
      // logged by the catch below instead of failing the pull page.
      await _ensureOwnerIndex(tableName);
    } catch (e, st) {
      developer.log(
        'parent table schema reconcile failed for $doctype/$tableName: $e',
        name: 'OfflineRepository',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// `buildParentSchemaDDL` and `AppDatabase._migrateV5ToV6` both index
  /// `owner`; a table that acquires the audit columns HERE instead would keep
  /// the full scan that index exists to remove — which is exactly the tables
  /// this reconcile exists for (created between an upgrade and the next pull,
  /// or provisioned outside the migration path). Not gated on "we just added
  /// `owner`": a host that provisions its own table WITH the columns and
  /// without the index lands in the same place. `IF NOT EXISTS` makes the
  /// per-pull re-run free.
  ///
  /// Name and quoting match `AppDatabase._migrateV5ToV6` exactly so all three
  /// provisioning paths converge on one index rather than creating two under
  /// different names.
  Future<void> _ensureOwnerIndex(String tableName) async {
    final suffix = stripDocsPrefix(tableName);
    await _database.rawDatabase.execute(
      'CREATE INDEX IF NOT EXISTS "ix_${suffix}_owner" ON "$tableName"(owner)',
    );
  }

  /// Returns [doc] with child-table rows attached to [doc.data] under each
  /// Table field's fieldname. Reads from the per-child-doctype SQLite tables
  /// (`docs__<child_doctype>`) by `parent_uuid = doc.localId`, ordered by
  /// `idx`. Each row is exposed with `name` mapped from `server_name`
  /// (matching the shape the form builder receives from the API).
  ///
  /// Used when opening a document in offline mode, where the resolver's flat
  /// row does not embed child arrays.
  ///
  /// The DB fetch (this method) and the merge ([mergeChildRowsIntoData]) are
  /// split so the merge can be unit-tested with plain maps, no database.
  Future<Document> attachChildRows(
    String doctype,
    Document doc,
    DocTypeMeta meta,
  ) async {
    final db = _database.rawDatabase;
    final childRowsByField = <String, List<Map<String, dynamic>>>{};
    for (final field in meta.fields) {
      final fname = field.fieldname;
      final ftype = field.fieldtype;
      if (fname == null) continue;
      if (ftype != 'Table' && ftype != 'Table MultiSelect') continue;
      final childDoctype = field.options;
      if (childDoctype == null || childDoctype.isEmpty) continue;
      final childTable = normalizeDoctypeTableName(childDoctype);
      if (!await sqliteTableExists(db, childTable)) continue;
      final rows = await db.query(
        childTable,
        where: 'parent_uuid = ?',
        whereArgs: [doc.localId],
        orderBy: 'idx ASC',
      );
      childRowsByField[fname] = rows
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    }
    if (childRowsByField.isEmpty) return doc;
    return doc.copyWith(
      data: mergeChildRowsIntoData(doc.data, meta, childRowsByField),
    );
  }
}

/// Pure merge step behind [OfflineRepository.attachChildRows]: no I/O, no
/// database — takes the parent document's data map plus already-fetched
/// child rows (keyed by the parent Table/Table MultiSelect fieldname) and
/// returns the data map with those fields populated.
///
/// For every field in [meta] with `fieldtype` `Table` or `Table MultiSelect`
/// that has a matching entry in [childRowsByField], each row is copied and
/// `server_name` is aliased to `name` when `name` is absent — matching the
/// shape the form builder receives from the live API — so `enriched[fname]`
/// ends up identical whether the document was read online or offline.
/// Fields absent from [childRowsByField] (no matching child table, or no
/// rows found) are left untouched in [parentData].
///
/// Extracted so this merge can be unit-tested with plain maps/fixtures,
/// independent of the SQLite fetch in [OfflineRepository.attachChildRows].
Map<String, dynamic> mergeChildRowsIntoData(
  Map<String, dynamic> parentData,
  DocTypeMeta meta,
  Map<String, List<Map<String, dynamic>>> childRowsByField,
) {
  final enriched = Map<String, dynamic>.from(parentData);
  for (final field in meta.fields) {
    final fname = field.fieldname;
    final ftype = field.fieldtype;
    if (fname == null) continue;
    if (ftype != 'Table' && ftype != 'Table MultiSelect') continue;
    final rows = childRowsByField[fname];
    if (rows == null) continue;
    enriched[fname] = rows.map((r) {
      final m = Map<String, dynamic>.from(r);
      // Map server_name → name so field values align with Frappe convention.
      if (!m.containsKey('name') && m.containsKey('server_name')) {
        m['name'] = m['server_name'];
      }
      return m;
    }).toList();
  }
  return enriched;
}

/// Returns true if [meta] declares at least one `Table` / `Table MultiSelect`
/// field — i.e. [OfflineRepository.attachChildRows] would have something to
/// hydrate for this doctype. Pure (no I/O); lets callers skip the child-row
/// fetch entirely for doctypes with no children instead of running a no-op
/// loop over every mobile-form meta on every detail read.
bool metaHasChildTableFields(DocTypeMeta meta) {
  return meta.fields.any(
    (f) => f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect',
  );
}
