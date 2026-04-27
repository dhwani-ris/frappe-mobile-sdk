import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../api/client.dart';
import '../database/app_database.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import 'offline_repository.dart';

/// Per-doctype sync phase observable from outside the SDK. Drives UX:
/// `initial` → blocking "preparing offline data" screen,
/// `resume`  → same screen with a "resuming" hint,
/// `incremental` → silent background indicator only.
enum DoctypePullPhase {
  /// No cursor persisted — the doctype has never been pulled. Next
  /// call will fetch the entire dataset.
  initial,

  /// Cursor persisted with `complete=false` — a previous initial pull
  /// was interrupted (network drop, app kill, crash) and the next call
  /// will resume from the last applied row.
  resume,

  /// Cursor persisted with `complete=true` — the doctype has finished
  /// at least one full pull. Subsequent calls are delta pulls that
  /// only fetch rows modified since the cursor.
  incremental,
}

/// Service for bi-directional sync
class SyncService {
  final FrappeClient _client;
  final OfflineRepository _repository;
  final AppDatabase _database; // ignore: unused_field
  final Future<String?> Function()? _getMobileUuid;
  bool _isSyncing = false;

  SyncService(
    this._client,
    this._repository,
    this._database, {
    Future<String?> Function()? getMobileUuid,
  }) : _getMobileUuid = getMobileUuid;

  /// Check if device is online
  Future<bool> isOnline() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.contains(ConnectivityResult.mobile) ||
        connectivityResult.contains(ConnectivityResult.wifi) ||
        connectivityResult.contains(ConnectivityResult.ethernet);
  }

  /// Sync all dirty documents (push)
  Future<SyncResult> pushSync({String? doctype}) async {
    if (_isSyncing) {
      return SyncResult(0, 0, 0, 'Sync already in progress', errors: []);
    }

    if (!await isOnline()) {
      return SyncResult(0, 0, 0, 'No internet connection', errors: []);
    }

    _isSyncing = true;
    int success = 0;
    int failed = 0;
    int total = 0;
    final List<SyncError> errors = [];

    try {
      final dirtyDocs = doctype != null
          ? await _repository.getDirtyDocumentsByDoctype(doctype)
          : await _repository.getDirtyDocuments();

      total = dirtyDocs.length;

      for (final doc in dirtyDocs) {
        try {
          if (doc.status == 'deleted') {
            if (doc.serverId != null) {
              try {
                await _client.document.deleteDocument(
                  doc.doctype,
                  doc.serverId!,
                );
              } catch (e) {
                rethrow;
              }
            }
            await _repository.hardDeleteDocument(doc.localId);
            success++;
          } else if (doc.serverId == null) {
            try {
              var data = Map<String, dynamic>.from(doc.data);
              final existingUuid = data['mobile_uuid'] as String?;
              if ((existingUuid == null || existingUuid.isEmpty) &&
                  _getMobileUuid != null) {
                final uuid = await _getMobileUuid();
                if (uuid != null && uuid.isNotEmpty) {
                  data['mobile_uuid'] = uuid;
                }
              }
              data = await _resolveLinkedUuids(doc.doctype, data);
              final result = await _client.document.createDocument(
                doc.doctype,
                data,
              );

              final serverId =
                  result['name'] as String? ?? result['docname'] as String?;
              if (serverId != null) {
                final updated = doc.copyWith(
                  serverId: serverId,
                  status: 'clean',
                  modified: DateTime.now().millisecondsSinceEpoch,
                );
                await _repository.updateDocument(updated);
                // Update server_name in per-doctype tables for parent + children.
                try {
                  await _repository.markPushed(
                    doctype: doc.doctype,
                    mobileUuid: doc.localId,
                    serverName: serverId,
                    serverData: result,
                  );
                } catch (_) {}
              }
            } catch (e) {
              rethrow;
            }
            success++;
          } else {
            try {
              await _client.document.updateDocument(
                doc.doctype,
                doc.serverId!,
                doc.data,
              );
            } catch (e) {
              rethrow;
            }

            final updated = doc.markClean();
            await _repository.updateDocument(updated);
            success++;
          }
        } catch (e) {
          final errorMsg = e.toString();
          failed++;

          // Track error details
          final operation = doc.status == 'deleted'
              ? 'delete'
              : (doc.serverId == null ? 'create' : 'update');
          errors.add(
            SyncError(
              documentId: doc.serverId ?? doc.localId,
              doctype: doc.doctype,
              operation: operation,
              errorMessage: errorMsg,
            ),
          );
        }
      }

      return SyncResult(success, failed, total, null, errors: errors);
    } finally {
      _isSyncing = false;
    }
  }

  /// Returns the current pull phase of [doctype] — drives UI choices
  /// (blocking screen vs background indicator) without forcing the
  /// caller to crack the cursor JSON open.
  Future<DoctypePullPhase> getPullPhase(String doctype) async {
    final raw = await _database.doctypeMetaDao.getLastOkCursor(doctype);
    if (raw == null || raw.isEmpty) return DoctypePullPhase.initial;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m['complete'] == true
          ? DoctypePullPhase.incremental
          : DoctypePullPhase.resume;
    } catch (_) {
      // Corrupted cursor reads as INITIAL — the next pull will refresh it.
      return DoctypePullPhase.initial;
    }
  }

  /// Bulk-fetch [getPullPhase] for many doctypes in one DB scan.
  /// Useful for the bootstrap screen: "12 of 45 doctypes ready".
  Future<Map<String, DoctypePullPhase>> getPullPhases(
    List<String> doctypes,
  ) async {
    final out = <String, DoctypePullPhase>{};
    for (final dt in doctypes) {
      out[dt] = await getPullPhase(dt);
    }
    return out;
  }

  /// Pull updates from server
  Future<SyncResult> pullSync({required String doctype, int? since}) async {
    if (_isSyncing) {
      return SyncResult(0, 0, 0, 'Sync already in progress', errors: []);
    }

    if (!await isOnline()) {
      return SyncResult(0, 0, 0, 'No internet connection', errors: []);
    }

    _isSyncing = true;
    try {
      return await _pullOneInternal(doctype: doctype, since: since);
    } finally {
      _isSyncing = false;
    }
  }

  /// Pull updates for many doctypes with bounded parallelism.
  ///
  /// Used by initial-sync to drain ~45 doctypes through a small worker
  /// pool instead of awaiting them one at a time. The `_isSyncing` flag
  /// is held once for the entire batch; individual doctype failures do
  /// not abort the rest.
  Future<Map<String, SyncResult>> pullSyncMany({
    required List<String> doctypes,
    int concurrency = 4,
  }) async {
    if (_isSyncing) {
      return {
        for (final dt in doctypes)
          dt: SyncResult(0, 0, 0, 'Sync already in progress', errors: []),
      };
    }

    if (!await isOnline()) {
      return {
        for (final dt in doctypes)
          dt: SyncResult(0, 0, 0, 'No internet connection', errors: []),
      };
    }

    _isSyncing = true;
    final results = <String, SyncResult>{};
    int next = 0;

    Future<void> worker() async {
      while (true) {
        final myIdx = next++;
        if (myIdx >= doctypes.length) return;
        final dt = doctypes[myIdx];
        try {
          results[dt] = await _pullOneInternal(doctype: dt);
        } catch (e) {
          results[dt] = SyncResult(0, 0, 0, e.toString(), errors: [
            SyncError(
              documentId: '',
              doctype: dt,
              operation: 'pull',
              errorMessage: e.toString(),
            ),
          ]);
        }
      }
    }

    try {
      final workerCount =
          concurrency.clamp(1, doctypes.isEmpty ? 1 : doctypes.length);
      await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
      return results;
    } finally {
      _isSyncing = false;
    }
  }

  /// Single-doctype pull body. Does NOT touch `_isSyncing` or do
  /// connectivity checks — callers are responsible for both, so the same
  /// body is shared between [pullSync] (per-call gate) and [pullSyncMany]
  /// (batch-level gate).
  ///
  /// ────────────────────────────────────────────────────────────────────
  /// Two distinct phases, encoded in the persisted cursor JSON
  /// (`doctype_meta.last_ok_cursor`):
  ///
  ///   • INITIAL phase — the doctype has never finished a full pull.
  ///     Cursor is either NULL (never started) or
  ///     `{modified, name, complete: false}` (started but interrupted).
  ///     A NULL cursor means the entire dataset is fetched (no filter).
  ///     A complete-false cursor means we're RESUMING from a crash /
  ///     network drop and only want the unprocessed suffix.
  ///
  ///   • INCREMENTAL phase — the doctype has at least one completed
  ///     full pull. Cursor is `{modified, name, complete: true}` and
  ///     subsequent calls do delta pulls — only rows whose
  ///     `(modified, name)` strictly exceeds the cursor are applied.
  ///     The cursor advances on every successful delta page so future
  ///     deltas pull only the newest changes.
  ///
  /// Filter semantics (mechanically the same for RESUME and INCREMENTAL
  /// — see comment below for why we use `>=` + tie-skip in both):
  ///
  ///   INITIAL (no cursor)        no filter         no tie-skip
  ///   RESUME (complete=false)    modified >= mod   skip <= (mod,name)
  ///   INCREMENTAL (complete=true)modified >= mod   skip <= (mod,name)
  ///
  /// On the final page (a short page that says "no more rows"), the
  /// cursor is rewritten with `complete: true` — flipping the doctype
  /// from INITIAL/RESUME to INCREMENTAL. From that point on, every
  /// future call is a delta pull.
  ///
  /// Why `>=` + tie-skip in INCREMENTAL too (vs strict `>`): Frappe's
  /// `modified` is set at request time and CAN collide on the second
  /// when two rows are written together. A strict `>` filter would
  /// silently skip a same-microsecond newer-name row created after our
  /// cursor was set. `>=` plus tie-skip catches them — at the cost of
  /// one cursor-row overlap per delta call (1 wasted upsert).
  ///
  /// Legacy [since] (epoch ms) is honoured only when there is no
  /// persisted cursor — preserves the old `syncDoctype` flow's
  /// behaviour for callers that still pass it.
  /// ────────────────────────────────────────────────────────────────────
  Future<SyncResult> _pullOneInternal({
    required String doctype,
    int? since,
  }) async {
    int success = 0;
    int failed = 0;
    int total = 0;
    final List<SyncError> errors = [];

    // Load + parse persisted cursor. Three observable states:
    //   cursorModified == null              → INITIAL (no cursor)
    //   cursorModified != null, complete=F  → RESUME (initial-in-progress)
    //   cursorModified != null, complete=T  → INCREMENTAL (delta)
    String? cursorModified;
    String? cursorName;
    bool cursorComplete = false;
    final cursorRaw = await _database.doctypeMetaDao.getLastOkCursor(doctype);
    if (cursorRaw != null && cursorRaw.isNotEmpty) {
      try {
        final m = jsonDecode(cursorRaw) as Map<String, dynamic>;
        final mv = m['modified'];
        final nv = m['name'];
        final cv = m['complete'];
        if (mv is String && mv.isNotEmpty) cursorModified = mv;
        if (nv is String && nv.isNotEmpty) cursorName = nv;
        cursorComplete = cv == true;
      } catch (_) {
        // Corrupted cursor — treat as fresh INITIAL pull.
      }
    }

    // Build server filter — see phase table in the docstring above.
    final filters = <List<dynamic>>[];
    if (cursorModified != null) {
      filters.add(['modified', '>=', cursorModified]);
    } else if (since != null) {
      filters.add([
        'modified',
        '>',
        DateTime.fromMillisecondsSinceEpoch(since).toIso8601String(),
      ]);
    }

    // If the parent meta declares any `Table` / `Table MultiSelect`
    // field, the bare `frappe.client.get_list` response is missing
    // child arrays — we need full docs (`/api/resource/<doctype>/<name>`).
    // Otherwise the cheaper flat `get_list` is fine. We resolve the
    // meta from cache (or doctype_meta DAO) so this works for
    // returning users where `ensureSchemaForClosure` ran on a previous
    // launch only.
    final needsFullDoc =
        _repository.doctypesWithChildren().contains(doctype) ||
            await _doctypeHasChildTables(doctype);

    // Paginate via `limit_start` until the server returns a short page
    // (fewer rows than requested). Without this, doctypes with > 1000
    // rows (Village, Hamlet, etc.) silently truncate at the first page.
    // Page size is the API cap, not a UX choice.
    const int pageSize = 1000;
    // Stable order is required for the cursor to be valid: the server
    // must return the unprocessed suffix in the same order on every
    // call. `name asc` breaks ties when multiple rows share `modified`.
    const String orderBy = 'modified asc, name asc';
    // Look-ahead is REACTIVE, not speculative: page N+1 is fired only
    // after page N comes back full-sized. Small doctypes (<= pageSize
    // rows) therefore make exactly one HTTP call — no wasted GETs.
    // Multi-page doctypes keep one extra page in-flight while the
    // current page's rows are written to SQLite (so apply overlaps with
    // network), giving the same 2x throughput as the previous
    // speculative scheme without the small-doctype tax.
    Future<List<dynamic>> fetchPage(int start) {
      return needsFullDoc
          ? _client.doctype.listFullDocs(
              doctype,
              filters: filters.isEmpty ? null : filters,
              limitStart: start,
              limitPageLength: pageSize,
              orderBy: orderBy,
            )
          : _client.doctype.list(
              doctype,
              filters: filters.isEmpty ? null : filters,
              fields: ['*'],
              limitStart: start,
              limitPageLength: pageSize,
              orderBy: orderBy,
            );
    }

    int start = 0;
    Future<List<dynamic>> currentFetch = fetchPage(start);

    while (true) {
      final page = await currentFetch;
      if (page.isEmpty) break;
      total += page.length;

      // Only fire a look-ahead when this page came back full — i.e.
      // there is reason to believe the next page exists. A short page
      // means we're done, no extra GET needed.
      Future<List<dynamic>>? lookahead;
      if (page.length >= pageSize) {
        lookahead = fetchPage(start + pageSize);
      }

      // Track the cursor advance for this page so we can persist it
      // exactly once after the page drains. Updating per-row would
      // burn extra UPDATE statements without changing crash-safety.
      String? pageLastModified;
      String? pageLastName;

      // Apply the current page to SQLite. When `lookahead` was fired,
      // this work overlaps with the network request.
      for (final docData in page) {
        if (docData is! Map<String, dynamic>) continue;
        final serverId =
            (docData['name'] as String?) ?? (docData['docname'] as String?);
        final modifiedAt = docData['modified'] as String? ?? '';
        if (serverId == null || serverId.isEmpty) continue;

        // Skip rows from the cursor's tie group that we already
        // applied on a previous run. Only relevant on resume — the
        // first page may include the cursor row plus same-`modified`
        // peers that sort before it under `name asc`.
        if (cursorModified != null && cursorName != null) {
          final modCmp = modifiedAt.compareTo(cursorModified);
          if (modCmp < 0) continue;
          if (modCmp == 0 && serverId.compareTo(cursorName) <= 0) continue;
        }

        try {
          await _repository.saveServerDocument(
            doctype: doctype,
            serverId: serverId,
            data: docData,
          );
          success++;
          pageLastModified = modifiedAt;
          pageLastName = serverId;
        } catch (e) {
          failed++;
          errors.add(SyncError(
            documentId: serverId,
            doctype: doctype,
            operation: 'pull',
            errorMessage: e.toString(),
          ));
        }
      }

      // Whether THIS page is the last one for the current pull. The
      // look-ahead is only fired when the current page came back full
      // (page.length >= pageSize); a null look-ahead therefore means
      // "no more rows" — the doctype is fully drained and the cursor
      // can flip to complete=true (transition from INITIAL/RESUME →
      // INCREMENTAL, or stay INCREMENTAL).
      final bool isFinalPage = lookahead == null;

      // Journal cursor advance after every page. The `complete` flag
      // is the load-bearing bit:
      //   * non-final pages → complete=false   (resume marker)
      //   * final page      → complete=true    (delta watermark)
      // `setLastOkCursor` also stamps `last_pull_ok_at`, so a successful
      // page leaves both the cursor and a "last activity" timestamp
      // updated atomically.
      if (pageLastModified != null && pageLastName != null) {
        await _database.doctypeMetaDao.setLastOkCursor(
          doctype,
          jsonEncode({
            'modified': pageLastModified,
            'name': pageLastName,
            'complete': isFinalPage,
          }),
        );
        cursorModified = pageLastModified;
        cursorName = pageLastName;
        if (isFinalPage) cursorComplete = true;
      } else if (isFinalPage && cursorModified != null && !cursorComplete) {
        // Edge case: server returned a page (possibly all skipped via
        // tie-skip) and the next page is empty — no row was applied
        // here, but the doctype IS drained. Promote the existing
        // cursor to complete=true so we don't get stuck in RESUME
        // forever for an unchanged doctype.
        await _database.doctypeMetaDao.setLastOkCursor(
          doctype,
          jsonEncode({
            'modified': cursorModified,
            'name': cursorName,
            'complete': true,
          }),
        );
        cursorComplete = true;
      }

      if (lookahead == null) break;
      start += pageSize;
      currentFetch = lookahead;
    }

    return SyncResult(success, failed, total, null, errors: errors);
  }

  /// Resolves local mobile_uuid values to server_names for all Link fields
  /// in [doctype]'s parent payload AND inside every child table row.
  ///
  /// Lookup order per UUID:
  ///   1. Legacy `documents` table — `localId = uuid` with a non-null
  ///      `serverId` (set immediately after a successful push in this pass).
  ///   2. Per-doctype `docs__<target>` table — `mobile_uuid = uuid` with
  ///      a non-null `server_name` (set after a server pull or markSynced).
  ///
  /// No-ops gracefully on missing meta, missing tables, or any DB error.
  Future<Map<String, dynamic>> _resolveLinkedUuids(
    String doctype,
    Map<String, dynamic> data,
  ) async {
    final raw = await _database.doctypeMetaDao.getMetaJson(doctype);
    if (raw == null || raw.isEmpty || raw == '{}') return data;
    DocTypeMeta meta;
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      meta = DocTypeMeta.fromJson(parsed);
    } catch (_) {
      return data;
    }
    return _rewritePayload(meta, data);
  }

  Future<Map<String, dynamic>> _rewritePayload(
    DocTypeMeta meta,
    Map<String, dynamic> data,
  ) async {
    final resolved = Map<String, dynamic>.from(data);
    for (final field in meta.fields) {
      final fname = field.fieldname;
      if (fname == null) continue;

      if (field.fieldtype == 'Link') {
        final targetDoctype = field.options;
        if (targetDoctype == null || targetDoctype.isEmpty) continue;
        final value = resolved[fname] as String?;
        if (value == null || value.isEmpty || !_looksLikeMobileUuid(value)) {
          continue;
        }
        final serverName = await _uuidToServerName(targetDoctype, value);
        if (serverName != null) resolved[fname] = serverName;
      } else if (field.fieldtype == 'Table' ||
          field.fieldtype == 'Table MultiSelect') {
        final childDoctype = field.options;
        if (childDoctype == null || childDoctype.isEmpty) continue;
        final list = resolved[fname];
        if (list is! List || list.isEmpty) continue;
        final childRaw =
            await _database.doctypeMetaDao.getMetaJson(childDoctype);
        if (childRaw == null || childRaw.isEmpty) continue;
        DocTypeMeta childMeta;
        try {
          final parsed = jsonDecode(childRaw) as Map<String, dynamic>;
          childMeta = DocTypeMeta.fromJson(parsed);
        } catch (_) {
          continue;
        }
        final rewritten = <dynamic>[];
        for (final row in list) {
          if (row is Map) {
            rewritten.add(
              await _rewritePayload(childMeta, Map<String, dynamic>.from(row)),
            );
          } else {
            rewritten.add(row);
          }
        }
        resolved[fname] = rewritten;
      }
    }
    return resolved;
  }

  /// Resolves a mobile_uuid to its server name. Checks the legacy
  /// `documents` table first (populated immediately after a successful push
  /// in this same sync pass), then the per-doctype table.
  Future<String?> _uuidToServerName(
    String targetDoctype,
    String uuid,
  ) async {
    // 1. Legacy documents table — localId = uuid, serverId set by updateDocument
    try {
      final doc = await _repository.getDocumentByLocalId(uuid);
      if (doc?.serverId != null && doc!.serverId!.isNotEmpty) {
        return doc.serverId;
      }
    } catch (_) {}

    // 2. Per-doctype table — server_name set by pull or markSynced
    try {
      final targetTable = normalizeDoctypeTableName(targetDoctype);
      final db = _database.rawDatabase;
      final tableCheck = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [targetTable],
      );
      if (tableCheck.isEmpty) return null;
      final rows = await db.query(
        targetTable,
        columns: ['server_name'],
        where: 'mobile_uuid = ? AND server_name IS NOT NULL',
        whereArgs: [uuid],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return rows.first['server_name'] as String?;
      }
    } catch (_) {}

    return null;
  }

  static final _uuidRegex = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  static bool _looksLikeMobileUuid(String value) => _uuidRegex.hasMatch(value);

  Future<bool> _doctypeHasChildTables(String doctype) async {
    final raw = await _database.doctypeMetaDao.getMetaJson(doctype);
    if (raw == null || raw.isEmpty || raw == '{}') return false;
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final meta = DocTypeMeta.fromJson(parsed);
      for (final f in meta.fields) {
        if (f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Full sync (push + pull) for a DocType
  Future<SyncResult> syncDoctype(String doctype) async {
    if (_isSyncing) {
      return SyncResult(0, 0, 0, 'Sync already in progress', errors: []);
    }

    if (!await isOnline()) {
      return SyncResult(0, 0, 0, 'No internet connection', errors: []);
    }

    _isSyncing = true;

    try {
      final pushResult = await pushSync(doctype: doctype);

      final localDocs = await _repository.getDocumentsByDoctype(doctype);
      int? lastModified;
      if (localDocs.isNotEmpty) {
        lastModified = localDocs
            .map((d) => d.modified)
            .reduce((a, b) => a > b ? a : b);
      }

      final pullResult = await pullSync(doctype: doctype, since: lastModified);

      final allErrors = <SyncError>[];
      allErrors.addAll(pushResult.errors);
      allErrors.addAll(pullResult.errors);

      return SyncResult(
        pushResult.success + pullResult.success,
        pushResult.failed + pullResult.failed,
        pushResult.total + pullResult.total,
        null,
        errors: allErrors,
      );
    } finally {
      _isSyncing = false;
    }
  }

  /// Get sync statistics
  Future<Map<String, int>> getSyncStats({String? doctype}) async {
    final dirtyDocs = doctype != null
        ? await _repository.getDirtyDocumentsByDoctype(doctype)
        : await _repository.getDirtyDocuments();

    final deletedCount = dirtyDocs.where((d) => d.status == 'deleted').length;
    final dirtyCount = dirtyDocs.where((d) => d.status == 'dirty').length;

    return {
      'dirty': dirtyCount,
      'deleted': deletedCount,
      'total': dirtyDocs.length,
    };
  }
}

/// Result of sync operation
class SyncResult {
  final int success;
  final int failed;
  final int total;
  final String? error;
  final List<SyncError> errors;

  SyncResult(
    this.success,
    this.failed,
    this.total,
    this.error, {
    List<SyncError>? errors,
  }) : errors = errors ?? [];
}

/// Individual sync error details
class SyncError {
  final String documentId;
  final String doctype;
  final String operation;
  final String errorMessage;
  final DateTime timestamp;

  SyncError({
    required this.documentId,
    required this.doctype,
    required this.operation,
    required this.errorMessage,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() {
    return '$operation failed for $doctype/$documentId: $errorMessage';
  }
}
