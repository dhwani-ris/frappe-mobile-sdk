import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../api/client.dart';
import '../api/exceptions.dart';
import '../concurrency/concurrency_pool.dart';
import '../concurrency/device_tier.dart';
import '../concurrency/write_queue.dart';
import '../database/app_database.dart';
import '../database/daos/outbox_dao.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../database/sqlite_utils.dart';
import '../database/table_name.dart';
import '../models/meta_resolver.dart';
import '../sync/idempotency_strategy.dart';
import '../sync/pull_engine.dart';
import '../sync/pull_page_fetcher.dart';
import '../sync/push_engine.dart';
import '../sync/push_error.dart';
import '../sync/error_log_collector.dart';
import '../sync/mobile_error_poster.dart';
import '../sync/mobile_error_record.dart' show excTypeFromBody;
import '../sync/sync_state_notifier.dart';
import 'error_capture.dart';
import 'offline_repository.dart';
import 'session_user_service.dart';
import 'sync_controller.dart';
import '../utils/sdk_log.dart';

// Re-export so callers building the SDK pack can name the typedef.
export '../sync/push_engine.dart' show PayloadTransformerFn;

/// True when [e] is Frappe's `QueryDeadlockError` — MySQL/MariaDB error
/// 1213 ("Deadlock found when trying to get lock; try restarting
/// transaction"), surfaced as HTTP 500. Concurrent INSERTs that share a
/// naming series race on the `tabSeries` counter row and one is chosen as
/// the deadlock victim and rolled back. The transaction committed nothing,
/// so the request is safe to retry — [PushEngine] does, via [DeadlockError].
///
/// Detection is on the response body's `exc_type`/text rather than the
/// status code alone, so it survives proxies that rewrite 500s.
bool isDeadlockApiException(ApiException e) {
  final details = e.details;
  if (details is Map && details['exc_type'] == 'QueryDeadlockError') {
    return true;
  }
  final haystack = '${e.message} $details'.toLowerCase();
  return haystack.contains('querydeadlockerror') ||
      haystack.contains('deadlock found') ||
      haystack.contains('(1213,') ||
      haystack.contains('error 1213');
}

/// Bridges the API-layer `FrappeException` hierarchy
/// (`ApiException`/`ValidationException`/`AuthException`/`NetworkException`,
/// thrown by `RestHelper`) onto the push-layer [PushError] hierarchy that
/// [PushEngine] classifies. Without this, every server rejection escaped as a
/// raw `ApiException` to the engine's catch-all `markFailed(UNKNOWN)`, so the
/// timestamp auto-merge, duplicate reconcile, terminal→`paused`, and
/// network-retry paths were all unreachable.
///
/// Routing is by Frappe `exc_type` first (most precise), then HTTP status.
/// Anything unrecognised becomes a [ServerRejection], whose `toErrorCode()`
/// maps known `exc_type`s (PermissionError/ValidationError/MandatoryError) and
/// otherwise falls back to status — preserving the prior `UNKNOWN` outcome for
/// genuinely unclassifiable failures.
PushError frappeToPushError({
  int? status,
  required String? excType,
  required String rawBody,
}) {
  switch (excType) {
    case 'TimestampMismatchError':
      return TimestampMismatchError();
    case 'DuplicateEntryError':
      return DuplicateEntryError();
    case 'LinkExistsError':
      // H4 (reviewer asked to populate the linked-document list; verified
      // INVALID): Frappe's LinkExistsError carries no structured linked map.
      // `raise_link_exists_exception` (delete_doc.py) throws on the FIRST
      // blocking link with a translated HTML message in `_server_messages` —
      // there is no doctype→names list to parse, and only one reference is
      // ever named. So `linked` stays empty; the human message reaches the UI
      // via the engine's stored error_message / sync_error_banner.
      return LinkExistsError(linked: const {});
  }
  // H3: a 409 WITHOUT exc_type is NOT necessarily an optimistic-lock mismatch
  // — duplicate-name and custom-app conflicts also return 409 with no
  // exc_type. Defaulting to TimestampMismatchError triggers a refresh+retry
  // that just hits the same 409 and loops until the budget exhausts, then
  // mislabels the cause. Genuine timestamp mismatches DO carry
  // exc_type=TimestampMismatchError (handled above), so fall through to a
  // generic ServerRejection here.
  return ServerRejection(status: status ?? 500, rawBody: rawBody);
}

/// `exc_type` from a stamped FrappeException's response body, or null when
/// absent ([excTypeFromBody] returns '' for "not present"; normalise to null
/// so [frappeToPushError]'s status fallbacks engage).
String? _excTypeOf(FrappeException e) {
  final raw = excTypeFromBody(e.responseBodyRaw);
  return raw.isEmpty ? null : raw;
}

/// The real HTTP dispatch used by [SyncEngineBuilder]'s push engine. Routes a
/// push operation to the matching `DocumentService` call and translates the
/// API-layer `FrappeException` it may throw onto the push-layer [PushError]
/// the engine classifies. [onFailure] (the per-drain error-log capture) is
/// invoked for terminal HTTP failures before the translated error is thrown —
/// identical to the prior capture-then-rethrow, so error-log behaviour is
/// unchanged. Top-level (not a closure) so tests can exercise the exact
/// production path instead of a mirror.
Future<Map<String, dynamic>> dispatchHttpSend(
  FrappeClient client,
  String method,
  Map<String, Object?> payload,
  String? serverName, {
  void Function(FrappeException e, String method, Map<String, Object?> payload)?
  onFailure,
}) async {
  final doctype = payload['doctype'] as String;
  try {
    switch (method) {
      case 'POST':
        return await client.document.createDocument(
          doctype,
          Map<String, dynamic>.from(payload),
        );
      case 'PUT':
        return await client.document.updateDocument(
          doctype,
          serverName!,
          Map<String, dynamic>.from(payload),
        );
      case 'SUBMIT':
        return await client.document.submitDocument(doctype, serverName!);
      case 'CANCEL':
        return await client.document.cancelDocument(doctype, serverName!);
      case 'DELETE':
        await client.document.deleteDocument(doctype, serverName!);
        return const <String, dynamic>{};
      default:
        throw StateError('dispatchHttpSend: unknown method "$method"');
    }
  } on ApiException catch (e) {
    // A server-side deadlock is transient — translate it to the retryable
    // [DeadlockError] so PushEngine's attempt loop retries it (with jitter).
    // Deadlocks are retried, not logged.
    if (isDeadlockApiException(e)) {
      throw DeadlockError(message: e.message);
    }
    onFailure?.call(e, method, payload);
    throw frappeToPushError(
      status: e.statusCode,
      excType: _excTypeOf(e),
      rawBody: e.responseBodyRaw ?? jsonEncode({'message': e.message}),
    );
  } on ValidationException catch (e) {
    // HTTP 417 validate()-hook failure. The body may carry a more specific
    // exc_type (MandatoryError/LinkExistsError).
    onFailure?.call(e, method, payload);
    throw frappeToPushError(
      status: 417,
      excType: _excTypeOf(e),
      rawBody: e.responseBodyRaw ?? jsonEncode({'exc_type': 'ValidationError'}),
    );
  } on AuthException catch (e) {
    // B2: distinguish 401 (session expiry) from 403 (permission denial).
    // A 401 reaches here only after RestHelper's token-refresh attempt has
    // already failed. It is NOT terminal: once the user re-authenticates, the
    // queued rows must still push. Classifying it as PermissionError would
    // mark every pending row `paused`, silently killing the queue on any
    // mid-sync session timeout. Route it to the retryable NetworkError bucket
    // (retryAll re-attempts after re-auth). Only a genuine 403 is terminal.
    if (e.statusCode == 401) {
      throw NetworkError(message: e.message);
    }
    onFailure?.call(e, method, payload);
    throw frappeToPushError(
      status: e.statusCode ?? 403,
      excType: 'PermissionError',
      rawBody:
          e.responseBodyRaw ??
          jsonEncode({'exc_type': 'PermissionError', 'message': e.message}),
    );
  } on NetworkException catch (e) {
    // Transient connectivity failure — retryable bucket. M1: deliberately
    // does NOT call onFailure. Network errors are out of scope for the error
    // log (spec §6); they have no HTTP status to classify and would otherwise
    // flood the log on every offline blip. Do not add onFailure here for
    // symmetry with the other branches — the omission is intentional.
    throw NetworkError(message: e.message);
  }
}

/// Bundle of the engines + façade that `FrappeSDK` stashes after wiring.
class SyncEnginePack {
  final SyncStateNotifier notifier;
  final ConcurrencyPool pullPool;
  final ConcurrencyPool pushPool;
  final PushEngine pushEngine;
  final PullEngine pullEngine;
  final SyncController controller;

  const SyncEnginePack({
    required this.notifier,
    required this.pullPool,
    required this.pushPool,
    required this.pushEngine,
    required this.pullEngine,
    required this.controller,
  });
}

/// One-shot wiring helper. Pure-construction; no side effects beyond the
/// objects it returns.
class SyncEngineBuilder {
  static Future<SyncEnginePack> build({
    required AppDatabase database,
    required FrappeClient client,
    required MetaResolverFn metaResolver,
    required Future<Set<String>> Function() runPullFn,
    required Future<void> Function(String doctype, Map<String, dynamic> doc)
    applyServerDoc,
    required Future<void> Function(Set<String> doctypes) runPullForDoctypes,
    bool serverHasDedupHook = false,
    int? concurrencyOverride,
    SyncStateNotifier? sharedNotifier,
    SchemaReconcilerFn? schemaReconciler,
    PayloadTransformerFn? payloadTransformer,
    int pullPageSize = 500,
    SessionUserService? sessionUserService,
  }) async {
    final notifier = sharedNotifier ?? SyncStateNotifier();
    final tier = await DeviceTier.detect(override: concurrencyOverride);
    final pullPool = ConcurrencyPool(maxConcurrent: tier);
    final pushPool = ConcurrencyPool(maxConcurrent: tier);

    final rawDb = database.rawDatabase;
    final outboxDao = OutboxDao(rawDb);

    // Per-drain error-log capture: terminal push failures are side-channelled
    // here and flushed (best-effort) to mobile_control on drain completion.
    final errorLogCollector = ErrorLogCollector();
    final errorLogPoster = MobileErrorPoster(
      call: (m, a) => client.call(m, args: a),
    );
    final attachmentDao = PendingAttachmentDao(rawDb);
    final metaDao = database.doctypeMetaDao;

    // Side-channels a terminal push failure into the error-log collector.
    // Wired as [dispatchHttpSend]'s `onFailure`: it runs (best-effort, never
    // throws) on the original FrappeException *before* that exception is
    // translated to a PushError and thrown. So error-log capture is
    // independent of — and unchanged by — the PushError classification.
    void captureSendFailure(
      FrappeException e,
      String method,
      Map<String, Object?> payload,
    ) {
      final user = sessionUserService?.current;
      // Safe variant: capture must never throw and mask the original
      // FrappeException the caller is about to rethrow.
      recordTerminalFailureSafe(
        collector: errorLogCollector,
        method: method,
        payload: payload,
        error: e,
        sessionUserName: user?.name ?? '',
        sessionUserRoles: user?.roles ?? const [],
        nowMillis: DateTime.now().toUtc().millisecondsSinceEpoch,
      );
    }

    // ----- HTTP send callback -----
    // Delegates to the top-level [dispatchHttpSend] (so tests exercise the
    // real path, not a mirror). The error-log capture is wired as `onFailure`,
    // preserving the prior capture-then-throw behaviour; `dispatchHttpSend`
    // then translates the FrappeException onto the engine's PushError types.
    Future<Map<String, dynamic>> send(
      String method,
      Map<String, Object?> payload,
      String? serverName,
    ) => dispatchHttpSend(
      client,
      method,
      payload,
      serverName,
      onFailure: captureSendFailure,
    );

    // ----- serverFetcher -----
    Future<Map<String, dynamic>> serverFetcher(
      String doctype,
      String serverName,
    ) => client.doctype.getByName(doctype, serverName);

    // ----- serverLookupByUuid (L3 idempotency probe) -----
    Future<Map<String, dynamic>?> serverLookupByUuid(
      String doctype,
      String mobileUuid,
    ) async {
      try {
        final list = await client.doctype.list(
          doctype,
          filters: [
            ['mobile_uuid', '=', mobileUuid],
          ],
          limitPageLength: 1,
        );
        if (list.isEmpty) return null;
        final first = list.first;
        if (first is Map) {
          return Map<String, dynamic>.from(first);
        }
        return null;
      } catch (e, st) {
        sdkLog(
          'SyncEngineBuilder.serverLookupByUuid: lookup failed for '
          '$doctype/$mobileUuid — $e\n$st',
        );
        return null;
      }
    }

    // ----- attachment uploader -----
    Future<Map<String, dynamic>> attachmentUploader(
      File file, {
      String? doctype,
      String? docname,
      String? fileName,
      bool isPrivate = true,
    }) => client.attachment.uploadFile(
      file,
      fileName: fileName,
      doctype: doctype,
      docname: docname,
      isPrivate: isPrivate,
    );

    // ----- resolveServerName -----
    Future<String?> resolveServerName(
      String targetDoctype,
      String mobileUuid,
    ) => _resolveServerNameFor(rawDb, targetDoctype, mobileUuid);

    // ----- Per-doctype WriteQueue cache -----
    final writeQueueCache = <String, WriteQueue>{};
    WriteQueue writeQueueResolver(String doctype) {
      return writeQueueCache.putIfAbsent(
        doctype,
        () => WriteQueue(db: rawDb, doctype: doctype),
      );
    }

    final idempotencyStrategy = IdempotencyStrategy(
      serverHasDedupHook: serverHasDedupHook,
      onInitWarning: (msg) {
        sdkLog('IdempotencyStrategy: $msg');
      },
    );

    final pushEngine = PushEngine(
      db: rawDb,
      outboxDao: outboxDao,
      attachmentDao: attachmentDao,
      metaDao: metaDao,
      pool: pushPool,
      notifier: notifier,
      idempotencyStrategy: idempotencyStrategy,
      metaResolver: metaResolver,
      childMetaResolver: metaResolver,
      send: send,
      serverFetcher: serverFetcher,
      serverLookupByUuid: serverLookupByUuid,
      resolveServerName: resolveServerName,
      attachmentUploader: attachmentUploader,
      writeQueueResolver: writeQueueResolver,
      payloadTransformer: payloadTransformer,
      // M3: drain() materialises + clears the collector; if flush() then fails
      // (e.g. network), those aggregated records are dropped, NOT re-queued.
      // This loss-on-failure is intentional — error logs are best-effort
      // telemetry, not a guaranteed audit log (spec §9). Do not add retry/
      // re-queue logic here: it would counterproductively keep PII-bearing
      // examples in memory and re-POST on every drain.
      onDrainComplete: () => errorLogPoster.flush(errorLogCollector.drain()),
    );

    // The list-http callback backs the closure PullEngine. A flat
    // `frappe.client.get_list` returns PARENT scalar fields only — child-table
    // arrays are dropped — so a parent that declares any Table / Table
    // MultiSelect field must be fetched via `mobile_sync.get_docs_with_children`
    // (listFullDocs) to embed its children. PullApply already writes embedded
    // child arrays into docs__<child>; without this branch every child table
    // stays empty offline (broken form prefill / not truly offline-first).
    Future<ListHttpPage> listHttp(
      String doctype,
      Map<String, Object?> params,
    ) async {
      final limitPageLength =
          params['limit_page_length'] as int? ?? pullPageSize;
      final limitStart = params['limit_start'] as int? ?? 0;
      final filters = (params['filters'] as List?)?.cast<List<dynamic>>();
      final orderBy = params['order_by'] as String?;

      bool hasChildren = false;
      try {
        final meta = await metaResolver(doctype);
        hasChildren = metaHasChildTableFields(meta);
      } catch (e, st) {
        // Do NOT silently degrade to the flat list() path — that reintroduces
        // the empty-child-table bug this branch exists to prevent (a form
        // prefilled with blank child tables is worse than a visible failure).
        // Log and fail this doctype's pull; PullEngine's mid-pull catch records
        // it and retries next cycle without aborting the other doctypes.
        // (PullEngine resolves the same meta just before calling this, so
        // reaching here means a transient resolve failure.)
        sdkLog(
          'SyncEngineBuilder.listHttp($doctype): meta resolve failed — failing '
          'the pull rather than fetching without children — $e\n$st',
        );
        rethrow;
      }

      // The child-bearing path reports `namesScanned` so PullPageFetcher can
      // advance the offset by names consumed and recognise a fully
      // permission-filtered page as "skip", not "end of stream". It also reports
      // the SCANNED window's `(modified, name)` high-water mark, which is the
      // only thing that lets the INCREMENTAL pull (where `limit_start` is pinned
      // at 0, so there is no offset to step) move past a window whose every name
      // the per-doc gate denied. The flat path returns every row it lists, so it
      // leaves all three null.
      if (hasChildren) {
        final page = await client.doctype.listFullDocsPage(
          doctype,
          filters: filters,
          limitStart: limitStart,
          limitPageLength: limitPageLength,
          orderBy: orderBy,
        );
        return ListHttpPage(
          page.docs,
          namesScanned: page.namesScanned,
          scannedMaxModified: page.scannedMaxModified,
          scannedMaxName: page.scannedMaxName,
        );
      }

      final result = await client.doctype.list(
        doctype,
        filters: filters,
        fields: (params['fields'] as List?)?.cast<String>(),
        orderBy: orderBy,
        limitPageLength: limitPageLength,
        limitStart: limitStart,
      );
      return ListHttpPage(
        result
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(),
      );
    }

    final pullEngine = PullEngine(
      db: rawDb,
      metaDao: metaDao,
      outboxDao: outboxDao,
      pool: pullPool,
      fetcher: PullPageFetcher(listHttp: listHttp),
      pageSize: pullPageSize,
      notifier: notifier,
      metaResolver: metaResolver,
      writeQueueResolver: writeQueueResolver,
      schemaReconciler: schemaReconciler,
    );

    Future<void> clearLocalConflict(String doctype, String mobileUuid) async {
      final tableName =
          await metaDao.getTableName(doctype) ??
          normalizeDoctypeTableName(doctype);
      // Flip to `synced` (not `dirty`) — the caller (resolveConflict's
      // empty-serverName branch) is about to delete the outbox row, so
      // there is no pending work to push. Setting `dirty` here would
      // leave the row visually stuck-unsynced with nothing in the
      // outbox to drive a push. The next user edit will re-route as
      // INSERT (server_name is still NULL) and enqueue a fresh outbox
      // row. PR#36 round-2 H2 fix.
      await rawDb.update(
        tableName,
        <String, Object?>{'sync_status': 'synced', 'sync_error': null},
        where: 'mobile_uuid = ? AND sync_status = ?',
        whereArgs: [mobileUuid, 'conflict'],
      );
    }

    final controller = SyncController(
      outboxDao: outboxDao,
      notifier: notifier,
      runPull: runPullFn,
      runPush: () => pushEngine.runOnce(),
      runPullForDoctypes: runPullForDoctypes,
      fetchSingleDoc: serverFetcher,
      applySingleDoc: applyServerDoc,
      resolveServerName: resolveServerName,
      clearLocalConflict: clearLocalConflict,
    );

    return SyncEnginePack(
      notifier: notifier,
      pullPool: pullPool,
      pushPool: pushPool,
      pushEngine: pushEngine,
      pullEngine: pullEngine,
      controller: controller,
    );
  }
}

/// Test seam — `_resolveServerNameFor` is private; expose via this thin
/// `@visibleForTesting` wrapper so the resolver's edge cases can be
/// exercised directly without driving a full PushEngine retry path.
@visibleForTesting
Future<String?> debugResolveServerNameFor(
  Database db,
  String targetDoctype,
  String mobileUuid,
) => _resolveServerNameFor(db, targetDoctype, mobileUuid);

/// Looks up a target doctype's `server_name` from its `docs__<target>`
/// row keyed by `mobile_uuid`. Returns null when:
///  - the per-doctype table has not been provisioned yet
///  - no row exists for the given uuid
///  - the row exists but `server_name` is NULL (the doc has not been pushed)
Future<String?> _resolveServerNameFor(
  Database db,
  String targetDoctype,
  String mobileUuid,
) async {
  final tableName = normalizeDoctypeTableName(targetDoctype);
  if (!await sqliteTableExists(db, tableName)) {
    if (kDebugMode) {
      debugPrint(
        '[DIAG resolveServerName] table_missing target=$targetDoctype '
        'table=$tableName uuid=$mobileUuid',
      );
    }
    return null;
  }
  // Diagnostic dump (debug builds only — the extra `SELECT *` would
  // double the query cost per resolve in release, and these `[DIAG …]`
  // lines would flood production logs on every resolve). Use SELECT *
  // so it works for both parent and child docs__ tables (child has
  // parent_uuid/idx, parent doesn't). Wrap in try/catch so a diag
  // failure never breaks the resolver. PR#36 round-2 M8.
  if (kDebugMode) {
    try {
      final allRows = await db.query(
        tableName,
        where: 'mobile_uuid = ?',
        whereArgs: [mobileUuid],
      );
      final summary = allRows
          .map(
            (r) => {
              'mobile_uuid': r['mobile_uuid'],
              'server_name': r['server_name'],
              if (r.containsKey('parent_uuid')) 'parent_uuid': r['parent_uuid'],
              if (r.containsKey('parentfield')) 'parentfield': r['parentfield'],
              if (r.containsKey('idx')) 'idx': r['idx'],
              if (r.containsKey('sync_status')) 'sync_status': r['sync_status'],
            },
          )
          .toList();
      debugPrint(
        '[DIAG resolveServerName] target=$targetDoctype uuid=$mobileUuid '
        'matchingRows=${allRows.length} rows=$summary',
      );
    } catch (e, st) {
      debugPrint(
        '[DIAG resolveServerName] dump_failed target=$targetDoctype '
        'uuid=$mobileUuid err=$e\n$st',
      );
    }
  }
  final rows = await db.query(
    tableName,
    columns: ['server_name'],
    where: 'mobile_uuid = ? AND server_name IS NOT NULL',
    whereArgs: [mobileUuid],
    limit: 1,
  );
  if (rows.isEmpty) {
    if (kDebugMode) {
      debugPrint(
        '[DIAG resolveServerName] returning_null target=$targetDoctype '
        'uuid=$mobileUuid (no row with non-null server_name)',
      );
    }
    return null;
  }
  final result = rows.first['server_name'] as String?;
  if (kDebugMode) {
    debugPrint(
      '[DIAG resolveServerName] resolved target=$targetDoctype '
      'uuid=$mobileUuid → $result',
    );
  }
  return result;
}
