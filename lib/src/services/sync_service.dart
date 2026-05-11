import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:meta/meta.dart';
import '../api/client.dart';
import '../concurrency/concurrency_pool.dart';
import '../concurrency/device_tier.dart';
import '../concurrency/sync_mutex.dart';
import '../database/app_database.dart';
import '../models/doc_type_meta.dart';
import '../models/offline_mode.dart';
import '../models/offline_mode_notifier.dart';
import '../sync/cursor.dart';
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
  // ignore: unused_field
  final Future<String?> Function()? _getMobileUuid;
  final SyncMutex _syncMutex = SyncMutex();

  final OfflineModeNotifier _modeNotifier;

  /// Live offline-mode value. Reads through [_modeNotifier] so
  /// mid-session flips by `FrappeSDK._applyOfflineFlag` take effect
  /// immediately at every gate site below.
  OfflineMode get offlineMode => _modeNotifier.value;

  /// Drives the actual push. When non-null, [pushSync] delegates to it
  /// (via [_syncMutex]) instead of running the legacy [_pushOneInternal]
  /// pipeline. Wired by `FrappeSDK` to `PushEngine.runOnce()`.
  final Future<void> Function()? _pushRunner;

  SyncService(
    this._client,
    this._repository,
    this._database, {
    Future<String?> Function()? getMobileUuid,
    OfflineMode offlineMode = const OfflineMode(
      enabled: true,
      isPersisted: true,
    ),
    OfflineModeNotifier? offlineModeNotifier,
    Future<void> Function()? pushRunner,
  }) : _getMobileUuid = getMobileUuid,
       _modeNotifier = offlineModeNotifier ?? OfflineModeNotifier(offlineMode),
       _pushRunner = pushRunner;

  /// Check if device is online.
  /// Returns false when offline mode is disabled, regardless of connectivity,
  /// so callers can use this method without a separate mode guard.
  Future<bool> isOnline() async {
    if (!offlineMode.enabled) return false;
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.contains(ConnectivityResult.mobile) ||
        connectivityResult.contains(ConnectivityResult.wifi) ||
        connectivityResult.contains(ConnectivityResult.ethernet);
  }

  /// Sync all dirty documents (push). Now a thin wrapper over
  /// [PushEngine.runOnce] via the injected [_pushRunner]. The
  /// [_syncMutex] still guards concurrent callers.
  ///
  /// The [doctype] parameter is informational — `PushEngine.runOnce`
  /// drains the entire outbox; per-doctype filtering can be added in a
  /// follow-up. When [_pushRunner] is null (e.g. tests that don't wire
  /// the engine), returns [SyncResult.empty()] and logs a warning.
  ///
  /// Detail counts (success/failure/error list) are not populated here;
  /// callers wanting that signal should subscribe to
  /// `SyncStateNotifier` (exposed via `sdk.sync.state$`).
  Future<SyncResult> pushSync({String? doctype}) async {
    if (!offlineMode.enabled) {
      return SyncResult.empty(status: SyncStatus.offlineModeDisabled);
    }
    bool online = false;
    try {
      online = await isOnline();
    } catch (e, st) {
      // Platform-channel failure (e.g. headless test environment without
      // connectivity_plus mocks). Treat as offline; surface the failure
      // mode in logs rather than silently swallowing it.
      // ignore: avoid_print
      print('SyncService.pushSync: isOnline() threw — $e\n$st');
    }
    if (!online) {
      return SyncResult(
        0,
        0,
        0,
        'No internet connection',
        errors: const [],
        status: SyncStatus.noConnectivity,
      );
    }
    final runner = _pushRunner;
    if (runner == null) {
      // ignore: avoid_print
      print(
        'SyncService.pushSync: pushRunner not wired; returning empty result',
      );
      return SyncResult.empty();
    }
    final result = await _syncMutex.tryProtect<bool>(() async {
      await runner();
      return true;
    });
    if (result == null) {
      return SyncResult(
        0,
        0,
        0,
        'Sync already in progress',
        errors: const [],
        status: SyncStatus.busy,
      );
    }
    return SyncResult(0, 0, 0, null, errors: const []);
  }

  // The legacy `_pushOneInternal` push pipeline (read dirty rows from
  // the `documents` table → HTTP via FrappeClient → write back) was
  // deleted in retirement Phase 6. PushEngine.runOnce() is now the only
  // push driver. SyncService.pushSync delegates to it via the injected
  // `pushRunner` callback.

  /// Returns the current pull phase of [doctype] — drives UI choices
  /// (blocking screen vs background indicator) without forcing the
  /// caller to crack the cursor JSON open.
  Future<DoctypePullPhase> getPullPhase(String doctype) async {
    final raw = await _database.doctypeMetaDao.getLastOkCursor(doctype);
    if (raw == null || raw.isEmpty) return DoctypePullPhase.initial;
    try {
      final cursor = Cursor.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      return cursor.complete
          ? DoctypePullPhase.incremental
          : DoctypePullPhase.resume;
    } catch (e, st) {
      // Corrupted cursor reads as INITIAL — the next pull will refresh it.
      // ignore: avoid_print
      print('SyncService.getPullPhase: corrupted cursor — $e\n$st');
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

  /// Pull updates from server. Public entrypoint — guarded by [_syncMutex].
  Future<SyncResult> pullSync({required String doctype, int? since}) async {
    if (!offlineMode.enabled) {
      return SyncResult.empty(status: SyncStatus.offlineModeDisabled);
    }
    if (!await isOnline()) {
      return SyncResult(
        0,
        0,
        0,
        'No internet connection',
        errors: const [],
        status: SyncStatus.noConnectivity,
      );
    }
    final result = await _syncMutex.tryProtect(
      () => _pullOneInternal(doctype: doctype, since: since),
    );
    return result ??
        SyncResult(
          0,
          0,
          0,
          'Sync already in progress',
          errors: const [],
          status: SyncStatus.busy,
        );
  }

  /// Pull-with-wait variant — used by background refreshers (Link
  /// pickers, list-screen reloads) where dropping the request leaves
  /// stale UI but blocking on the current holder is acceptable. By the
  /// time this resumes, the in-flight closure batch has likely already
  /// pulled this doctype, so the underlying call is usually a cheap
  /// incremental delta.
  Future<SyncResult> pullSyncWaiting({
    required String doctype,
    int? since,
  }) async {
    if (!offlineMode.enabled) {
      return SyncResult.empty(status: SyncStatus.offlineModeDisabled);
    }
    if (!await isOnline()) {
      return SyncResult(
        0,
        0,
        0,
        'No internet connection',
        errors: const [],
        status: SyncStatus.noConnectivity,
      );
    }
    return _syncMutex.protect(
      () => _pullOneInternal(doctype: doctype, since: since),
    );
  }

  /// Runs [fn] inside the sync mutex — same lock that [pullSync],
  /// [pullSyncMany], and [pushSync] use. Call this when an external driver
  /// (e.g. PullEngine) needs to participate in the serialisation contract
  /// without going through a SyncService-owned method.
  Future<T> protect<T>(Future<T> Function() fn) => _syncMutex.protect(fn);

  /// Pull updates for many doctypes with bounded parallelism.
  ///
  /// Used by initial-sync to drain ~45 doctypes through a small worker
  /// pool instead of awaiting them one at a time. The sync mutex is
  /// held once for the entire batch; individual doctype failures do
  /// not abort the rest.
  ///
  /// [concurrency] defaults to [DeviceTier.detect] (2/4/8) when omitted,
  /// matching the size of the SDK's `_pullPool`. Pass an explicit value
  /// only for tests or to artificially throttle.
  Future<Map<String, SyncResult>> pullSyncMany({
    required List<String> doctypes,
    int? concurrency,
  }) async {
    if (doctypes.isEmpty) return const {};
    if (!offlineMode.enabled) {
      return {
        for (final dt in doctypes)
          dt: SyncResult.empty(status: SyncStatus.offlineModeDisabled),
      };
    }
    if (!await isOnline()) {
      return {
        for (final dt in doctypes)
          dt: SyncResult(
            0,
            0,
            0,
            'No internet connection',
            errors: const [],
            status: SyncStatus.noConnectivity,
          ),
      };
    }
    final results = await _syncMutex.tryProtect(() async {
      final out = <String, SyncResult>{};
      final effectiveConcurrency = concurrency ?? await DeviceTier.detect();
      final pool = ConcurrencyPool(
        maxConcurrent: effectiveConcurrency.clamp(
          1,
          doctypes.isEmpty ? 1 : doctypes.length,
        ),
      );
      await Future.wait(
        doctypes.map(
          (dt) => pool.submit<void>(() async {
            try {
              out[dt] = await _pullOneInternal(doctype: dt);
            } catch (e, st) {
              // ignore: avoid_print
              print('SyncService.pullSyncMany($dt) failed — $e\n$st');
              out[dt] = SyncResult(
                0,
                0,
                0,
                e.toString(),
                errors: [
                  SyncError(
                    documentId: '',
                    doctype: dt,
                    operation: 'pull',
                    errorMessage: e.toString(),
                  ),
                ],
              );
            }
          }),
        ),
      );
      return out;
    });
    return results ??
        {
          for (final dt in doctypes)
            dt: SyncResult(
              0,
              0,
              0,
              'Sync already in progress',
              errors: const [],
              status: SyncStatus.busy,
            ),
        };
  }

  /// Single-doctype pull body. Does NOT take the sync mutex or do
  /// connectivity checks — callers are responsible for both, so the same
  /// body is shared between [pullSync] (per-call gate), [pullSyncMany]
  /// (batch-level gate), and [syncDoctype] (combined push+pull gate).
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
  /// True when [doctype] is a child table (`istable=1`). Frappe doesn't
  /// permit `frappe.client.get_list` on child doctypes — the request
  /// raises `PermissionError` (Insufficient Permission), which the SDK
  /// surfaces as a 500 + cascading DB locks while the failure unwinds.
  /// Children must come embedded in their parent's pull payload (via
  /// `mobile_sync.get_docs_with_children`), so there is no legitimate
  /// reason to call pullSync on a child doctype.
  ///
  /// Reads the persisted meta JSON; defensively returns `false` if no
  /// meta is on file so an unknown doctype isn't silently skipped.
  @visibleForTesting
  Future<bool> isChildTableForTest(String doctype) => _isChildTable(doctype);

  Future<bool> _isChildTable(String doctype) async {
    final raw = await _database.doctypeMetaDao.getMetaJson(doctype);
    if (raw == null || raw.isEmpty || raw == '{}') return false;
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      if (parsed.isEmpty) return false;
      return DocTypeMeta.fromJson(parsed).isTable;
    } catch (e, st) {
      // ignore: avoid_print
      print('SyncService._isChildTable($doctype) parse failed — $e\n$st');
      return false;
    }
  }

  Future<SyncResult> _pullOneInternal({
    required String doctype,
    int? since,
  }) async {
    // Child-table guard: see _isChildTable for rationale.
    if (await _isChildTable(doctype)) {
      return SyncResult(0, 0, 0, null, errors: const []);
    }

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
      } catch (e, st) {
        // Corrupted cursor — treat as fresh INITIAL pull.
        // ignore: avoid_print
        print('SyncService.pullSync: corrupted cursor — $e\n$st');
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
        (await _repository.doctypesWithChildren()).contains(doctype) ||
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
          await _repository.applyServerDocument(
            doctype: doctype,
            serverName: serverId,
            data: docData,
          );
          success++;
          pageLastModified = modifiedAt;
          pageLastName = serverId;
        } catch (e, st) {
          // ignore: avoid_print
          print(
            'SyncService.pullSync applyServerDocument($doctype/$serverId) failed — $e\n$st',
          );
          failed++;
          errors.add(
            SyncError(
              documentId: serverId,
              doctype: doctype,
              operation: 'pull',
              errorMessage: e.toString(),
            ),
          );
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

  // The legacy `_resolveLinkedUuids` / `_rewritePayload` /
  // `_uuidToServerName` / `_looksLikeMobileUuid` helpers were deleted in
  // retirement Phase 6. UUID rewriting on the push path now flows through
  // `UuidRewriter.rewrite` (uuid_rewriter.dart) inside `PayloadAssembler`,
  // keyed off the `__is_local` flag on docs__<doctype> rows. The docs__
  // server_name lookup that `_uuidToServerName` did is now provided by
  // `SyncEngineBuilder._resolveServerNameFor`.

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
    } catch (e, st) {
      // ignore: avoid_print
      print(
        'SyncService._doctypeHasChildTables($doctype) parse failed — $e\n$st',
      );
      return false;
    }
  }

  // `syncDoctype` was deleted in retirement Phase 6 — no production
  // caller existed. Use `pushSync()` + `pullSync(doctype:)` separately,
  // or go through `sdk.sync.syncNow()` (SyncController) for the combined
  // pull-then-push cycle.

  /// Get sync statistics
  Future<Map<String, int>> getSyncStats({String? doctype}) async {
    if (!offlineMode.enabled) {
      return const {'dirty': 0, 'deleted': 0, 'total': 0};
    }
    final dirtyDocs = await _repository.getDirtyDocuments(doctype: doctype);

    final deletedCount = dirtyDocs.where((d) => d.status == 'deleted').length;
    final dirtyCount = dirtyDocs.where((d) => d.status == 'dirty').length;

    return {
      'dirty': dirtyCount,
      'deleted': deletedCount,
      'total': dirtyDocs.length,
    };
  }
}

/// Why a [SyncResult] is what it is — lets the caller distinguish
/// "offline mode is off, nothing tried" from "tried, nothing to do" from
/// "couldn't try because offline / busy". Defaults to [ran] for legacy
/// callers that constructed `SyncResult(...)` positionally.
enum SyncStatus {
  /// Offline mode is disabled at the SDK level; the call short-circuited
  /// before any work. `success/failed/total` are zero by construction.
  offlineModeDisabled,

  /// Offline mode is enabled but the device has no connectivity right
  /// now. `error` is non-null with the connectivity message.
  noConnectivity,

  /// Another sync was already running and the mutex rejected this call.
  /// `error` is non-null with "Sync already in progress".
  busy,

  /// The sync executed. `success/failed/total` carry actual row counts;
  /// when `failed > 0`, `errors` lists per-row details. Note that a
  /// successful call with no dirty rows ALSO reports `ran` — `success=0`
  /// here means "tried, nothing to do".
  ran,
}

/// Result of sync operation
class SyncResult {
  final int success;
  final int failed;
  final int total;
  final String? error;
  final List<SyncError> errors;
  final SyncStatus status;

  SyncResult(
    this.success,
    this.failed,
    this.total,
    this.error, {
    List<SyncError>? errors,
    this.status = SyncStatus.ran,
  }) : errors = errors ?? [];

  /// Returns a no-op result. [status] defaults to [SyncStatus.ran] for
  /// "ran with nothing to do" callsites; pass
  /// [SyncStatus.offlineModeDisabled] when the SDK is in online-only mode
  /// and the call short-circuited, [SyncStatus.busy] when another sync
  /// holds the mutex, etc. Lets callers tell apart "didn't try" from
  /// "tried, no work".
  factory SyncResult.empty({SyncStatus status = SyncStatus.ran}) =>
      SyncResult(0, 0, 0, null, status: status);
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
