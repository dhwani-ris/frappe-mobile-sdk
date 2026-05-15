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

      final exists = await sqliteTableExists(db, tableName);
      final isChild = childDoctypes.contains(doctype) || meta.isTable;
      if (!exists) {
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
        // ignore: avoid_print
        print(
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
      // ignore: avoid_print
      print(
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
  /// `conflict`. `done`, `pending`, and `inFlight` are intentionally
  /// excluded — only stuck-and-needs-attention rows reach the UI.
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
              r.state == OutboxState.conflict,
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
    final List<String> doctypes;
    if (doctype != null) {
      doctypes = [doctype];
    } else {
      try {
        final rows = await db.rawQuery(
          "SELECT doctype FROM doctype_meta "
          "WHERE table_name IS NOT NULL AND table_name != ''",
        );
        doctypes = rows.map((r) => r['doctype'] as String).toList();
      } on DatabaseException catch (e, st) {
        // ignore: avoid_print
        print(
          'OfflineRepository.getDirtyDocuments: doctype_meta scan failed '
          '— $e\n$st',
        );
        return const [];
      }
    }
    final out = <Document>[];
    for (final dt in doctypes) {
      final tableName = normalizeDoctypeTableName(dt);
      if (!await sqliteTableExists(db, tableName)) continue;
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
        // ignore: avoid_print
        print(
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
    final childMetasByDoctype = <String, DocTypeMeta>{};
    if (parentMeta != null) {
      for (final f in parentMeta.fields) {
        final opt = f.options;
        if ((f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') &&
            opt != null &&
            opt.isNotEmpty) {
          final cm = await _loadMeta(opt);
          if (cm != null) childMetasByDoctype[opt] = cm;
        }
      }
    }

    final tableName = normalizeDoctypeTableName(doctype);
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
      // ignore: avoid_print
      print(
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
      } else if (parentMeta != null) {
        pushBase = jsonEncode(
          PayloadSerializer.serializeForBase(existing, parentMeta),
        );
      }
    }

    final existingServerName = existing?['server_name'] as String?;

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
  Future<void> deleteDocument({
    required String doctype,
    required String mobileUuid,
  }) async {
    if (!offlineMode.enabled) {
      _requireOnlineClient('deleteDocument');
      await client!.document.deleteDocument(doctype, mobileUuid);
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
                // ignore: avoid_print
                print(
                  'OfflineRepository.deleteDocument: child cascade delete '
                  'failed for $childDoctype — $e\n$st',
                );
              }
            }
          }
        } on DatabaseException catch (e, st) {
          // ignore: avoid_print
          print(
            'OfflineRepository.deleteDocument: hard-delete failed for '
            '$doctype/$mobileUuid — $e\n$st',
          );
        }
        return;
      }

      // Otherwise: tombstone the docs__ row.
      try {
        await txn.update(
          tableName,
          {'sync_status': 'deleted', 'sync_op': 'DELETE'},
          where: 'mobile_uuid = ?',
          whereArgs: [mobileUuid],
        );
      } on DatabaseException catch (e, st) {
        // ignore: avoid_print
        print(
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
    final meta = await _loadMeta(doctype);
    if (meta == null) {
      // Meta absent means the DocType schema was never synced — we cannot
      // write to a table whose columns we don't know. Throw so every caller
      // correctly classifies this as a failure (sync error counter, UI
      // error message) rather than silently skipping the apply and marking
      // the outbox row as done.
      throw StateError(
        'OfflineRepository.applyServerDocument: meta missing for $doctype; '
        'cannot apply server snapshot for $serverName',
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
      rows: [data],
    );
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
    if (!await sqliteTableExists(db, tableName)) {
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
    } catch (e, st) {
      developer.log(
        'parent table schema reconcile failed for $doctype/$tableName: $e',
        name: 'OfflineRepository',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Returns [doc] with child-table rows attached to [doc.data] under each
  /// Table field's fieldname. Reads from the per-child-doctype SQLite tables
  /// (`docs__<child_doctype>`) by `parent_uuid = doc.localId`, ordered by
  /// `idx`. Each row is exposed with `name` mapped from `server_name`
  /// (matching the shape the form builder receives from the API).
  ///
  /// Used when opening a document in offline mode, where the resolver's flat
  /// row does not embed child arrays.
  Future<Document> attachChildRows(
    String doctype,
    Document doc,
    DocTypeMeta meta,
  ) async {
    final db = _database.rawDatabase;
    final enriched = Map<String, dynamic>.from(doc.data);
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
      enriched[fname] = rows.map((r) {
        final m = Map<String, dynamic>.from(r);
        // Map server_name → name so field values align with Frappe convention.
        if (!m.containsKey('name') && m.containsKey('server_name')) {
          m['name'] = m['server_name'];
        }
        return m;
      }).toList();
    }
    return doc.copyWith(data: enriched);
  }
}
