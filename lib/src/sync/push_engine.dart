import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../concurrency/concurrency_pool.dart';
import '../concurrency/write_queue.dart';
import '../database/daos/doctype_meta_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';
import '../models/outbox_row.dart';
import 'attachment_pipeline.dart';
import 'idempotency_strategy.dart';
import 'payload_assembler.dart';
import 'push_error.dart';
import 'response_writeback.dart';
import 'sync_state_notifier.dart';
import 'tier_computer.dart';
import 'three_way_merge.dart';
import 'uuid_rewriter.dart';

/// Sends a push request. [method] is one of POST / PUT / SUBMIT / CANCEL /
/// DELETE — the consumer maps it to the right Frappe endpoint. [payload]
/// is fully-prepared (children nested, UUIDs rewritten, attachments
/// inlined). [serverName] is null for INSERT and the server name for the
/// rest.
typedef PushHttpSendFn = Future<Map<String, dynamic>> Function(
  String method,
  Map<String, Object?> payload,
  String? serverName,
);

/// Fetches the current server snapshot of a doc — used by the
/// TimestampMismatch auto-merge path, and by L1/L2 idempotency recovery
/// after a `DuplicateEntryError`.
typedef PushServerFetchFn = Future<Map<String, dynamic>> Function(
  String doctype,
  String serverName,
);

/// L3 idempotency lookup: GET keyed on `mobile_uuid`. Returns the
/// existing doc (with at least `name` + `modified`) if the server
/// already has a row for [mobileUuid], or null otherwise. Spec §5.7 L3.
///
/// Required only when stock Frappe is in play (no `autoname=field:mobile_uuid`,
/// no `before_insert` dedup hook). When unset, INSERT retries against
/// stock Frappe may duplicate on flaky networks — IdempotencyStrategy's
/// init warning surfaces this risk.
typedef PushServerLookupByUuidFn = Future<Map<String, dynamic>?> Function(
  String doctype,
  String mobileUuid,
);

/// Top-level orchestrator for the offline-first push path. Spec §5.2.
///
/// Pipeline per outbox row:
///   1. Upload pending attachments (AttachmentPipeline).
///   2. Assemble the payload (PayloadAssembler → UuidRewriter).
///   3. Inline `pending:<id>` attachment markers.
///   4. Dispatch via [send]; retry on transient network errors.
///   5. On success → ResponseWriteback (parent + children + outbox done).
///
/// Error matrix:
/// - `NetworkError` / `TimeoutError`: retry with backoff (default 2s/5s/10s);
///   final terminal failure → `outbox.markFailed`.
/// - `TimestampMismatchError`: refetch server snapshot via [serverFetcher],
///   ThreeWayMerge against ours and the outbox payload's base, persist
///   merged values, retry the row exactly once. Exhausted → `markConflict`.
/// - `LinkExistsError` (DELETE): `markFailed` with structured JSON.
/// - `BlockedByUpstream`: `markBlocked` (retried on next run after upstream
///   completes).
/// - `ServerRejection` (permission/validation/mandatory): `markFailed`
///   with the corresponding ErrorCode.
class PushEngine {
  final Database db;
  final OutboxDao outboxDao;
  final PendingAttachmentDao attachmentDao;
  final DoctypeMetaDao metaDao;
  final ConcurrencyPool pool;
  final SyncStateNotifier notifier;
  final IdempotencyStrategy idempotencyStrategy;
  final MetaResolverFn metaResolver;
  final MetaResolverFn childMetaResolver;
  final PushHttpSendFn send;
  final PushServerFetchFn serverFetcher;
  final PushServerLookupByUuidFn? serverLookupByUuid;
  final ResolveServerNameFn resolveServerName;
  final AttachmentUploadFn attachmentUploader;
  final DependenciesForRowFn dependencyScanner;
  final List<Duration> attachmentBackoff;
  final List<Duration> networkBackoff;

  /// Optional. When provided, every parent-side write (response writeback,
  /// auto-merge persist) is routed through the [WriteQueue] for that
  /// doctype — providing per-doctype serialisation across pull and push
  /// activity and batched fsyncs across consecutive writes. When null,
  /// each write opens its own `db.transaction(...)` directly (simpler,
  /// fine for tests and small datasets).
  final WriteQueueResolver? writeQueueResolver;

  /// Lazy cache of per-doctype WriteQueue instances. Created on first use
  /// when [writeQueueResolver] is non-null.
  final Map<String, WriteQueue> _writeQueues = {};

  PushEngine({
    required this.db,
    required this.outboxDao,
    required this.attachmentDao,
    required this.metaDao,
    required this.pool,
    required this.notifier,
    required this.idempotencyStrategy,
    required this.metaResolver,
    required this.childMetaResolver,
    required this.send,
    required this.serverFetcher,
    this.serverLookupByUuid,
    required this.resolveServerName,
    required this.attachmentUploader,
    DependenciesForRowFn? dependencyScanner,
    this.writeQueueResolver,
    this.attachmentBackoff = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    this.networkBackoff = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
  }) : dependencyScanner = dependencyScanner ?? _defaultDependencyScanner;

  /// Drains the outbox once. Call this on user save (debounced), on
  /// connectivity restore, on app resume, or via SyncController.syncNow().
  Future<void> runOnce() async {
    notifier.value = notifier.value.copyWith(isPushing: true);
    try {
      // Resume any in_flight rows left over from a crash mid-dispatch.
      await outboxDao.resetInFlightToPending();

      final pending = await outboxDao.findByState(OutboxState.pending);
      if (pending.isEmpty) return;

      final tiers = TierComputer.compute(
        rows: pending,
        dependenciesForRow: dependencyScanner,
      );

      for (final tier in tiers) {
        await Future.wait(
          tier.map((r) => pool.submit<void>(() => _process(r))),
        );
      }
    } finally {
      notifier.value = notifier.value.copyWith(isPushing: false);
    }
  }

  Future<void> _process(OutboxRow row) async {
    await outboxDao.markInFlight(row.id);
    try {
      final response = await _dispatchOnce(row);
      await _writeBack(row, response);
    } on TimestampMismatchError catch (e) {
      if (row.retryCount < 1) {
        await _autoMergeAndRetry(row, e);
      } else {
        await outboxDao.markConflict(row.id, errorMessage: e.message);
      }
    } on LinkExistsError catch (e) {
      await outboxDao.markFailed(
        row.id,
        errorCode: ErrorCode.LINK_EXISTS,
        errorMessage: e.asJsonString(),
      );
    } on BlockedByUpstream catch (e) {
      await outboxDao.markBlocked(row.id, reason: e.message);
    } on NetworkError catch (e) {
      await outboxDao.markFailed(
        row.id,
        errorCode: ErrorCode.NETWORK,
        errorMessage: e.message,
      );
    } on TimeoutError catch (e) {
      await outboxDao.markFailed(
        row.id,
        errorCode: ErrorCode.TIMEOUT,
        errorMessage: e.message,
      );
    } on ServerRejection catch (e) {
      await outboxDao.markFailed(
        row.id,
        errorCode: e.toErrorCode(),
        errorMessage: e.message,
      );
    } catch (e) {
      await outboxDao.markFailed(
        row.id,
        errorCode: ErrorCode.UNKNOWN,
        errorMessage: '$e',
      );
    }
  }

  /// Builds payload and dispatches a single attempt with network-retry.
  /// Returns the server response on success; throws push errors otherwise.
  ///
  /// Idempotency handling — Spec §5.7. INSERT only:
  /// - L1 (autoname=field:mobile_uuid): server `name == mobile_uuid`. On
  ///   `DuplicateEntryError`, fetch via `serverFetcher(doctype, mobileUuid)`
  ///   and treat as success.
  /// - L2 (consumer's `before_insert` dedup hook): error carries the
  ///   existing server name; fetch by it.
  /// - L3 (stock Frappe): before each retry on a network-class failure,
  ///   GET keyed on `mobile_uuid`. If a row comes back, the original POST
  ///   succeeded — adopt the response without retrying.
  ///
  /// UPDATE / SUBMIT / CANCEL / DELETE are naturally idempotent in
  /// Frappe (UPDATE via `check_if_latest`; SUBMIT/CANCEL via
  /// "already submitted/cancelled" errors; DELETE 404 ≈ already gone) and
  /// don't trigger any of these branches.
  Future<Map<String, dynamic>> _dispatchOnce(OutboxRow row) async {
    final meta = await metaResolver(row.doctype);
    // L1/L2/L3 selection — caches per-session per-doctype + emits
    // init warning on first L3 doctype lacking mobile_uuid.
    final decision = idempotencyStrategy.pick(meta);

    final attachments = AttachmentPipeline(
      dao: attachmentDao,
      uploader: attachmentUploader,
      backoff: attachmentBackoff,
    );
    final uploaded = await attachments.uploadPendingFor(row.mobileUuid);

    final childMetas = await _childMetasFor(meta);
    final parentTable = await metaDao.getTableName(row.doctype) ??
        normalizeDoctypeTableName(row.doctype);

    var payload = await PayloadAssembler.assemble(
      db: db,
      row: row,
      parentMeta: meta,
      parentTable: parentTable,
      childMetasByFieldname: childMetas,
      resolveServerName: resolveServerName,
    );
    payload = AttachmentPipeline.inlinePayload(payload, resolved: uploaded);

    final method = _methodFor(row.operation);
    final isInsert = row.operation == OutboxOperation.insert;

    Object? lastTransient;
    for (var attempt = 0; attempt <= networkBackoff.length; attempt++) {
      // L3 pre-retry GET. Only on retries (attempt > 0), only on INSERT,
      // only when the previous failure was network-class. If the server
      // already has a row keyed on mobile_uuid the prior POST committed —
      // adopt that response and stop retrying.
      if (isInsert &&
          attempt > 0 &&
          decision.level == IdempotencyLevel.preRetryGetCheck &&
          serverLookupByUuid != null &&
          (lastTransient is NetworkError || lastTransient is TimeoutError)) {
        final existing =
            await serverLookupByUuid!(row.doctype, row.mobileUuid);
        if (existing != null) return existing;
      }

      try {
        return await send(method, payload, row.serverName);
      } on DuplicateEntryError catch (e) {
        if (!isInsert) rethrow;
        return await _resolveDuplicate(row, decision, e);
      } on NetworkError catch (e) {
        lastTransient = e;
      } on TimeoutError catch (e) {
        lastTransient = e;
      }
      if (attempt < networkBackoff.length) {
        await Future<void>.delayed(networkBackoff[attempt]);
      }
    }
    // Re-raise the last transient so the caller's catch-block records it.
    if (lastTransient is NetworkError) throw lastTransient;
    if (lastTransient is TimeoutError) throw lastTransient;
    throw NetworkError(message: 'unknown network failure');
  }

  /// Recovers from a `DuplicateEntryError` on INSERT by fetching the
  /// existing server doc (Spec §5.7 L1/L2). Returns a synthetic "success"
  /// response so the caller writes back as if the original POST committed.
  Future<Map<String, dynamic>> _resolveDuplicate(
    OutboxRow row,
    IdempotencyDecision decision,
    DuplicateEntryError err,
  ) async {
    if (err.existingName != null) {
      // L2 with existing name in the exception body.
      return await serverFetcher(row.doctype, err.existingName!);
    }
    if (decision.level == IdempotencyLevel.userSetNaming) {
      // L1: name == mobile_uuid by definition.
      return await serverFetcher(row.doctype, row.mobileUuid);
    }
    // Fallback: error didn't carry the name and we're not in L1. Try the
    // mobile_uuid lookup if the consumer wired it; otherwise re-raise so
    // the row goes to `failed` and the user can decide.
    if (serverLookupByUuid != null) {
      final existing =
          await serverLookupByUuid!(row.doctype, row.mobileUuid);
      if (existing != null) return existing;
    }
    throw err;
  }

  Future<void> _writeBack(
    OutboxRow row,
    Map<String, dynamic> response,
  ) async {
    final meta = await metaResolver(row.doctype);
    final childMetas = await _childMetasFor(meta);
    final childTablesByFieldname = <String, String>{};
    for (final entry in childMetas.entries) {
      childTablesByFieldname[entry.key] =
          normalizeDoctypeTableName(entry.value.doctype);
    }
    final parentTable = await metaDao.getTableName(row.doctype) ??
        normalizeDoctypeTableName(row.doctype);
    if (writeQueueResolver != null) {
      final wq = _writeQueues.putIfAbsent(
        row.doctype,
        () => writeQueueResolver!(row.doctype),
      );
      await wq.submit<void>((txn) async {
        await ResponseWriteback.applyInTxn(
          txn: txn,
          row: row,
          parentTable: parentTable,
          childTablesByFieldname: childTablesByFieldname,
          response: response,
        );
      });
    } else {
      await ResponseWriteback.apply(
        db: db,
        row: row,
        parentTable: parentTable,
        childTablesByFieldname: childTablesByFieldname,
        response: response,
      );
    }
  }

  Future<void> _autoMergeAndRetry(
    OutboxRow row,
    TimestampMismatchError err,
  ) async {
    if (row.serverName == null) {
      await outboxDao.markConflict(
        row.id,
        errorMessage: 'TimestampMismatch on a row with no server_name',
      );
      return;
    }
    final fresh = await serverFetcher(row.doctype, row.serverName!);
    final parentTable = await metaDao.getTableName(row.doctype) ??
        normalizeDoctypeTableName(row.doctype);
    final currentRow = (await db.query(
      parentTable,
      where: 'mobile_uuid = ?',
      whereArgs: [row.mobileUuid],
      limit: 1,
    ))
        .first;
    final base = row.payload == null
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(row.payload!) as Map);
    final merged = ThreeWayMerge.mergeFields(
      base: base,
      ours: Map<String, Object?>.from(currentRow),
      theirs: Map<String, Object?>.from(fresh),
    );

    // Persist merged values + the server's modified into the local row.
    // The merged map may contain server-only keys (`name`, `creation`,
    // `owner`, etc.) that aren't columns on `docs__<doctype>` — filter
    // against the actual table schema to avoid SQLITE_ERROR.
    final tableCols = (await db.rawQuery('PRAGMA table_info($parentTable)'))
        .map((r) => r['name'] as String)
        .toSet();
    final mergedForUpdate = <String, Object?>{};
    for (final entry in merged.entries) {
      if (tableCols.contains(entry.key)) {
        mergedForUpdate[entry.key] = entry.value;
      }
    }
    mergedForUpdate['modified'] = fresh['modified'];
    mergedForUpdate['mobile_uuid'] = row.mobileUuid;

    final outboxUpdate = <String, Object?>{
      'state': OutboxState.pending.wireName,
      'retry_count': row.retryCount + 1,
      'payload': jsonEncode(merged),
    };

    // Route both writes through the per-doctype WriteQueue when wired so
    // they share a transaction with concurrent writeback activity. Falls
    // back to two direct db.update calls when no resolver is provided.
    if (writeQueueResolver != null) {
      final wq = _writeQueues.putIfAbsent(
        row.doctype,
        () => writeQueueResolver!(row.doctype),
      );
      await wq.submit<void>((txn) async {
        await txn.update(
          parentTable,
          mergedForUpdate,
          where: 'mobile_uuid = ?',
          whereArgs: [row.mobileUuid],
        );
        await txn.update(
          'outbox',
          outboxUpdate,
          where: 'id = ?',
          whereArgs: [row.id],
        );
      });
    } else {
      await db.update(
        parentTable,
        mergedForUpdate,
        where: 'mobile_uuid = ?',
        whereArgs: [row.mobileUuid],
      );
      await db.update(
        'outbox',
        outboxUpdate,
        where: 'id = ?',
        whereArgs: [row.id],
      );
    }

    final updated = await outboxDao.findById(row.id);
    if (updated != null) {
      await _process(updated);
    }
  }

  String _methodFor(OutboxOperation op) {
    switch (op) {
      case OutboxOperation.insert:
        return 'POST';
      case OutboxOperation.update:
        return 'PUT';
      case OutboxOperation.submit:
        return 'SUBMIT';
      case OutboxOperation.cancel:
        return 'CANCEL';
      case OutboxOperation.delete:
        return 'DELETE';
    }
  }

  Future<Map<String, ChildInfo>> _childMetasFor(DocTypeMeta meta) async {
    final map = <String, ChildInfo>{};
    for (final f in meta.fields) {
      if (f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') {
        if (f.options == null || f.fieldname == null) continue;
        final childMeta = await childMetaResolver(f.options!);
        final tableName = normalizeDoctypeTableName(f.options!);
        map[f.fieldname!] = _ChildInfoImpl(
          f.options!,
          childMeta,
          tableName,
        );
      }
    }
    return map;
  }

  /// Default heuristic: any UUID-shaped string in the outbox payload is
  /// treated as a potential mobile_uuid dependency. The TierComputer
  /// further filters this against the actual pending set, so over-matching
  /// is harmless.
  static List<String> _defaultDependencyScanner(OutboxRow row) {
    if (row.payload == null || row.payload!.isEmpty) return const [];
    final uuidRe = RegExp(
      r'\b[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
      caseSensitive: false,
    );
    return uuidRe
        .allMatches(row.payload!)
        .map((m) => m.group(0)!)
        .where((u) => u != row.mobileUuid)
        .toList();
  }
}

class _ChildInfoImpl implements ChildInfo {
  @override
  final String doctype;
  @override
  final DocTypeMeta meta;
  @override
  final String tableName;
  _ChildInfoImpl(this.doctype, this.meta, this.tableName);
}
