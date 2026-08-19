import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../concurrency/concurrency_pool.dart';
import '../concurrency/write_queue.dart';
import '../database/daos/doctype_meta_dao.dart';
import '../database/daos/outbox_dao.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../database/sqlite_utils.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';
import '../models/outbox_row.dart';
import 'attachment_pipeline.dart';
import 'child_table_info.dart';
import 'idempotency_strategy.dart';
import 'payload_assembler.dart';
import 'push_error.dart';
import 'response_writeback.dart';
import 'sync_state_notifier.dart';
import 'tier_computer.dart';
import 'three_way_merge.dart';
import 'uuid_rewriter.dart';
import '../utils/sdk_log.dart';
import '../utils/uuid_pattern.dart';

/// Sends a push request. [method] is one of POST / PUT / SUBMIT / CANCEL /
/// DELETE — the consumer maps it to the right Frappe endpoint. [payload]
/// is fully-prepared (children nested, UUIDs rewritten, attachments
/// inlined). [serverName] is null for INSERT and the server name for the
/// rest.
typedef PushHttpSendFn =
    Future<Map<String, dynamic>> Function(
      String method,
      Map<String, Object?> payload,
      String? serverName,
    );

/// Fetches the current server snapshot of a doc — used by the
/// TimestampMismatch auto-merge path, and by L1/L2 idempotency recovery
/// after a `DuplicateEntryError`.
typedef PushServerFetchFn =
    Future<Map<String, dynamic>> Function(String doctype, String serverName);

/// L3 idempotency lookup: GET keyed on `mobile_uuid`. Returns the
/// existing doc (with at least `name` + `modified`) if the server
/// already has a row for [mobileUuid], or null otherwise. Spec §5.7 L3.
///
/// Required only when stock Frappe is in play (no `autoname=field:mobile_uuid`,
/// no `before_insert` dedup hook). When unset, INSERT retries against
/// stock Frappe may duplicate on flaky networks — IdempotencyStrategy's
/// init warning surfaces this risk.
typedef PushServerLookupByUuidFn =
    Future<Map<String, dynamic>?> Function(String doctype, String mobileUuid);

/// Optional transformer invoked just before the SDK pushes a row to the
/// server. Receives the doctype, the assembled payload, and the parent
/// meta; returns a (possibly modified) payload that gets sent.
///
/// Use case: consumers can override `docstatus` (e.g. auto-submit
/// submittable doctypes on sync) or strip/inject metadata without
/// changing the local row's representation.
typedef PayloadTransformerFn =
    Map<String, dynamic> Function(
      String doctype,
      Map<String, dynamic> payload,
      DocTypeMeta meta,
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
/// - `BlockedByUpstream`: `markBlocked`. Raised when a Link target has no
///   `server_name` yet, when an attachment upload failed terminally, or when a
///   non-INSERT row's own document has not been created server-side. NOT
///   auto-retried — the drain reads only `pending`, so a blocked row re-enters
///   the queue via `SyncController.retry` / `retryAll` (where it sorts at
///   RetryPriority 2) or via a re-save, which `OutboxDao.recordSave` collapses.
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

  /// Optional payload transformer; runs after [PayloadAssembler.assemble]
  /// and before HTTP dispatch. See [PayloadTransformerFn].
  final PayloadTransformerFn? payloadTransformer;

  /// Optional. Invoked once at the end of every [runOnce] (in the `finally`,
  /// after the rerun loop completes). Used to flush the per-drain error-log
  /// collector. Best-effort: exceptions are swallowed so a flush failure can
  /// never break the push drain.
  final Future<void> Function()? onDrainComplete;

  /// RNG for backoff jitter. Deadlock victims that retry on a fixed
  /// schedule re-collide in lockstep; jitter spreads them out.
  final Random _rng = Random();

  /// Returns [base] plus up to +50% random jitter. A zero base (tests)
  /// yields zero so suites stay instant; a real backoff (2s/5s/10s) is
  /// spread across a window so concurrent retries don't re-collide.
  Duration _withJitter(Duration base) {
    if (base == Duration.zero) return base;
    final extraMs = (base.inMilliseconds * 0.5 * _rng.nextDouble()).round();
    return base + Duration(milliseconds: extraMs);
  }

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
    this.payloadTransformer,
    this.onDrainComplete,
    this.attachmentBackoff = kDefaultSyncBackoff,
    this.networkBackoff = kDefaultSyncBackoff,
  }) : dependencyScanner = dependencyScanner ?? _defaultDependencyScanner;

  bool _running = false;
  bool _rerunRequested = false;

  /// Drains the outbox once. Call this on user save (debounced), on
  /// connectivity restore, on app resume, or via SyncController.syncNow().
  ///
  /// Reentrancy guard: multiple triggers can fire concurrently (a user save
  /// racing a connectivity restore racing syncNow). Without serialization
  /// each call independently resets in_flight rows back to pending and
  /// re-fetches the outbox, dispatching the same row twice in parallel
  /// (PR#36 round-4 B1). A concurrent caller does not start a second drain;
  /// it requests exactly one more drain after the current one finishes, so
  /// work enqueued mid-drain is still picked up.
  Future<void> runOnce() async {
    if (_running) {
      _rerunRequested = true;
      return;
    }
    _running = true;
    notifier.value = notifier.value.copyWith(isPushing: true);
    try {
      do {
        _rerunRequested = false;
        await _drainOnce();
      } while (_rerunRequested);
    } finally {
      _running = false;
      notifier.value = notifier.value.copyWith(isPushing: false);
      final hook = onDrainComplete;
      if (hook != null) {
        // Fire-and-forget: best-effort telemetry must NOT extend the push
        // critical section. SyncService.pushSync awaits runOnce() while
        // holding _syncMutex (shared with pullSync), so awaiting a slow or
        // timing-out flush here would stall pulls. The hook captures its
        // data synchronously (errorLogCollector.drain() is evaluated when
        // the closure runs), so the network POST can finish in the
        // background after runOnce() resolves.
        try {
          unawaited(
            hook().catchError((Object e, StackTrace st) {
              sdkLog('PushEngine.onDrainComplete threw (ignored) — $e\n$st');
            }),
          );
        } catch (e, st) {
          sdkLog(
            'PushEngine.onDrainComplete threw synchronously (ignored) — $e\n$st',
          );
        }
      }
    }
  }

  /// One full drain pass over the outbox. Always invoked under the
  /// [runOnce] reentrancy guard — never call directly.
  Future<void> _drainOnce() async {
    // Resume any in_flight rows left over from a crash mid-dispatch.
    await outboxDao.resetInFlightToPending();

    // Supersede pass — for any (doctype, mobile_uuid, operation) tuple
    // with both a `failed` or `paused` row AND a newer `pending` row,
    // delete the older failed/paused row directly. Keeps the outbox a
    // true pending-work-only table (Invariant 2) and avoids a redundant
    // retry that the newer pending row already covers.
    await db.execute('''
        DELETE FROM outbox
         WHERE id IN (
           SELECT older.id
             FROM outbox older
             JOIN outbox newer
               ON older.doctype     = newer.doctype
              AND older.mobile_uuid = newer.mobile_uuid
              AND older.operation   = newer.operation
              AND older.state       IN ('${OutboxState.failed.wireName}', '${OutboxState.paused.wireName}')
              AND newer.state       = '${OutboxState.pending.wireName}'
              AND older.created_at  < newer.created_at
         )
      ''');

    final pending = await outboxDao.findByState(OutboxState.pending);
    if (pending.isEmpty) return;

    // Precompute real dependencies by scanning each pending row's
    // `docs__<doctype>` mirror (+ children) for `<field>__is_local=1`
    // Link values. Without this the default scanner returns `[]`
    // (no `payload` column on outbox), and TierComputer collapses
    // every row into tier 0 — racing parent INSERTs against dependent
    // child INSERTs whose UuidRewriter then sees the parent's
    // `server_name` as still-null and throws BlockedByUpstream.
    final depsByRowId = <int, List<String>>{};
    for (final row in pending) {
      depsByRowId[row.id] = await _scanLocalDepsFor(row);
    }

    final tiers = TierComputer.compute(
      rows: pending,
      dependenciesForRow: (r) => depsByRowId[r.id] ?? dependencyScanner(r),
    );

    for (final tier in tiers) {
      await Future.wait(_dispatchUnits(tier).map((u) => pool.submit<void>(u)));
    }
  }

  /// `created_at ASC, id ASC` — the order [OutboxDao.findByState] reads the
  /// outbox in, and the order rows must reach the server in.
  static int _byQueueOrder(OutboxRow a, OutboxRow b) {
    final cmp = a.createdAt.compareTo(b.createdAt);
    return cmp != 0 ? cmp : a.id.compareTo(b.id);
  }

  /// Splits a dispatch tier into independently-runnable units, preserving
  /// `created_at ASC` everywhere it is observable.
  ///
  /// Rows are read from the outbox in queue order and must leave in queue
  /// order. Tiering does not provide that — it only orders rows against
  /// *other documents'* uuids — so the ordering rules live here:
  ///
  /// 1. **Within a unit**, rows run strictly in `created_at, id` order. That
  ///    one rule also delivers per-document ordering for free: the enqueue
  ///    side stamps a document's rows in sequence — `saveDocument` writes the
  ///    INSERT/UPDATE row first and its SUBMIT/CANCEL row at
  ///    `created_at + 1ms` precisely so it lands after — so queue order
  ///    already implies "INSERT before everything else for that document".
  ///    Operations after the INSERT need the `server_name` that only its
  ///    writeback can produce.
  /// 2. **Units are emitted in queue order too**, keyed on their first row, so
  ///    the FIFO [pool] starts them in `created_at` order.
  /// 3. **Documents with an INSERT in this tier share one unit per doctype**,
  ///    so the server increments that doctype's naming-series counter
  ///    (`tabSeries`) one row at a time — N concurrent same-series INSERTs
  ///    deadlock on that counter row (MySQL/MariaDB 1213). Because that unit's
  ///    rows are sorted as a whole, the grouping cannot let one document's
  ///    later operation overtake another document's earlier one.
  ///
  /// Documents with no INSERT here get their own unit and run concurrently, so
  /// cross-doctype throughput is preserved; the [pool] still caps concurrency.
  /// Strict global `created_at` order ACROSS doctypes is deliberately not
  /// provided — that would mean abandoning rule 3 and serialising every
  /// doctype behind every other.
  ///
  /// Map keys are records, not concatenated strings: `(doctype, mobile_uuid)`
  /// is the identity the outbox uses everywhere else (`recordSave`, the
  /// supersede pass, the writeback's has-more probe), and a record compares
  /// structurally, so no separator can collide with a doctype name that
  /// contains one.
  List<Future<void> Function()> _dispatchUnits(List<OutboxRow> tier) {
    final docsWithInsert = <(String, String)>{};
    for (final r in tier) {
      if (r.operation == OutboxOperation.insert) {
        docsWithInsert.add((r.doctype, r.mobileUuid));
      }
    }

    final byUnit = <Object, List<OutboxRow>>{};
    for (final r in tier) {
      final Object key = docsWithInsert.contains((r.doctype, r.mobileUuid))
          ? ('doctype', r.doctype)
          : ('doc', r.doctype, r.mobileUuid);
      (byUnit[key] ??= <OutboxRow>[]).add(r);
    }

    // No sorting here: queue order is already established upstream and every
    // step preserves it. [OutboxDao.findByState] applies
    // `ORDER BY created_at ASC, id ASC` (served straight off
    // `ix_outbox_state(state, created_at)`, so SQLite does an ordered index
    // scan rather than a sort); [TierComputer] appends rows to a tier in that
    // same iteration order; and Dart's default Map/Set are insertion-ordered,
    // so bucketing keeps each unit's rows ordered AND emits the units
    // themselves in order of their first row. Re-sorting would only restate
    // what the index already guarantees. The assert below is the seatbelt: if
    // a future change upstream ever drops the ORDER BY or reorders a tier,
    // this fails loudly in debug instead of silently pushing out of order.
    assert(
      _isQueueOrdered(tier),
      'a dispatch tier arrived out of queue order — the outbox read or '
      'TierComputer stopped preserving `created_at ASC, id ASC`',
    );
    return [for (final u in byUnit.values) () => _processChain(u)];
  }

  /// True when [rows] are in `created_at ASC, id ASC` order. Debug-only
  /// invariant check for [_dispatchUnits]; not called in release builds.
  static bool _isQueueOrdered(List<OutboxRow> rows) {
    for (var i = 1; i < rows.length; i++) {
      if (_byQueueOrder(rows[i - 1], rows[i]) > 0) return false;
    }
    return true;
  }

  /// Runs one dispatch unit's rows strictly in sequence. A row that fails is
  /// already recorded by [_process] (it never rethrows for a classified push
  /// error), so the chain continues — a failed UPDATE must not strand the
  /// DELETE queued behind it.
  Future<void> _processChain(List<OutboxRow> chain) async {
    for (final r in chain) {
      await _process(r);
    }
  }

  Future<void> _process(OutboxRow row, {bool mergeAttempted = false}) async {
    await outboxDao.markInFlight(row.id);
    try {
      final response = await _dispatchOnce(row);
      await _writeBack(row, response);
    } on TimestampMismatchError catch (e) {
      // `mergeAttempted` breaks the merge-retry recursion: the slim
      // outbox no longer carries `retry_count`, so a counter-based guard
      // would always see 0 and recurse unbounded. The flag is local to
      // this dispatch chain; a user re-save would clear it because the
      // next dispatch starts from a fresh `runOnce` drain.
      if (!mergeAttempted) {
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
    } on DeadlockError catch (e) {
      // All deadlock retries exhausted. Record as NETWORK (the retryable
      // transient bucket, via toErrorCode) — not UNKNOWN — so the error UI
      // groups it under retryAll for a later, less-contended attempt.
      await outboxDao.markFailed(
        row.id,
        errorCode: e.toErrorCode(),
        errorMessage: e.message,
      );
    } on ServerRejection catch (e) {
      // #53: a terminal rejection (validation/mandatory/permission/link) can
      // never succeed on retry. Park it in `paused` (the drain reads only
      // `pending`, so it won't loop) instead of `failed`, which the user/retry
      // flow may re-attempt. A re-save of the corrected record re-queues it.
      final code = e.toErrorCode();
      if (code.isTerminal) {
        await outboxDao.markPaused(
          row.id,
          errorCode: code,
          errorMessage: e.message,
        );
      } else {
        await outboxDao.markFailed(
          row.id,
          errorCode: code,
          errorMessage: e.message,
        );
      }
    } catch (e, st) {
      sdkLog(
        'PushEngine: row(${row.id}, ${row.doctype}/${row.mobileUuid}) failed with unknown error — $e\n$st',
      );
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
      db: db,
      backoff: attachmentBackoff,
      tableNameFor: (dt) => metaDao.tableNameFor(dt),
      // Same lazy per-doctype cache the auto-merge persist uses, so the
      // attachment writeback serializes against the other `docs__` writers
      // instead of racing them.
      writeQueueFor: writeQueueResolver == null
          ? null
          : (dt) => _writeQueues.putIfAbsent(dt, () => writeQueueResolver!(dt)),
    );
    // Push gate: throws BlockedByUpstream unless every attachment is `done`.
    // Runs BEFORE PayloadAssembler.assemble below so the writeback has already
    // replaced each marker in `docs__` by the time the payload is built.
    await attachments.resolveForTopParent(row.mobileUuid);
    // Built from ALL rows, so a marker left by an interrupted writeback still
    // resolves rather than reaching the wire.
    final uploaded = await attachments.resolutionMapFor(row.mobileUuid);

    final childMetas = await _childMetasFor(meta);
    final parentTable = await metaDao.tableNameFor(row.doctype);

    // Read the per-doc snapshot — it's the canonical source of truth for
    // server_name and retry counters. The slim outbox no longer carries
    // these; they live on `docs__<doctype>` (retirement Phase 1).
    final docRows = await db.query(
      parentTable,
      columns: ['server_name', 'sync_attempts'],
      where: 'mobile_uuid = ?',
      whereArgs: [row.mobileUuid],
      limit: 1,
    );
    final docRow = docRows.isEmpty ? const <String, Object?>{} : docRows.first;
    final docServerName = docRow['server_name'] as String?;
    final docRetryCount = (docRow['sync_attempts'] as int?) ?? 0;

    // Every operation except INSERT addresses the doc by its server name, and
    // the consumer's `send` dereferences it (`dispatchHttpSend` does
    // `serverName!`). A null here means this doc's own INSERT has not landed:
    // either it is queued behind this row in the same chain and failed, or an
    // earlier drain already parked it in `failed` — in which case it is not in
    // the pending set at all and _dispatchUnits has no chain to order this row
    // against. Refuse to dispatch. Without this the null-check throws a
    // TypeError, which is not a PushError, so `_process`'s catch-all recorded
    // it as `markFailed(UNKNOWN)` — the least actionable code there is
    // (RetryPriority 7) and, for DELETE, only after the writeback had already
    // hard-deleted the local mirror. `blocked` is the honest state: it names
    // the upstream, sorts at RetryPriority 2, and is what `retryAll` picks up
    // once the INSERT has gone through.
    if (row.operation != OutboxOperation.insert &&
        (docServerName == null || docServerName.isEmpty)) {
      throw BlockedByUpstream(
        field: 'server_name',
        targetDoctype: row.doctype,
        targetUuid: row.mobileUuid,
        reason: "this document's INSERT has not reached the server yet",
      );
    }

    // Bump retry counter + last_attempt_at on each attempt.
    await db.update(
      parentTable,
      <String, Object?>{
        'sync_attempts': docRetryCount + 1,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'mobile_uuid = ?',
      whereArgs: [row.mobileUuid],
    );

    var payload = await PayloadAssembler.assemble(
      db: db,
      row: row,
      parentMeta: meta,
      parentTable: parentTable,
      childMetasByFieldname: childMetas,
      resolveServerName: resolveServerName,
    );
    payload = AttachmentPipeline.inlinePayload(payload, resolved: uploaded);

    final transformer = payloadTransformer;
    if (transformer != null) {
      try {
        payload = transformer(row.doctype, payload, meta);
      } catch (e, st) {
        sdkLog('PushEngine._dispatchOnce: payloadTransformer threw — $e\n$st');
        // Fall through with un-transformed payload — never block the push.
      }
    }

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
        final existing = await serverLookupByUuid!(row.doctype, row.mobileUuid);
        if (existing != null) return existing;
      }

      try {
        return await send(method, payload, docServerName);
      } on DuplicateEntryError catch (e) {
        if (!isInsert) rethrow;
        return await _resolveDuplicate(row, decision, e);
      } on NetworkError catch (e) {
        lastTransient = e;
      } on TimeoutError catch (e) {
        lastTransient = e;
      } on DeadlockError catch (e) {
        // Transient server contention (e.g. concurrent naming-series
        // INSERTs racing on `tabSeries`). The deadlocked transaction rolled
        // back, so nothing committed — retry the whole request after a
        // jittered delay. Without this branch the deadlock escaped as a raw
        // ApiException to `_process`'s terminal `markFailed(UNKNOWN)`.
        lastTransient = e;
      }
      if (attempt < networkBackoff.length) {
        await Future<void>.delayed(_withJitter(networkBackoff[attempt]));
      }
    }
    // Re-raise the last transient so the caller's catch-block records it.
    if (lastTransient is NetworkError) throw lastTransient;
    if (lastTransient is TimeoutError) throw lastTransient;
    if (lastTransient is DeadlockError) throw lastTransient;
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
      final existing = await serverLookupByUuid!(row.doctype, row.mobileUuid);
      if (existing != null) return existing;
    }
    throw err;
  }

  Future<void> _writeBack(OutboxRow row, Map<String, dynamic> response) async {
    final meta = await metaResolver(row.doctype);
    final childMetas = await _childMetasFor(meta);
    final childTablesByFieldname = <String, String>{};
    for (final entry in childMetas.entries) {
      childTablesByFieldname[entry.key] = normalizeDoctypeTableName(
        entry.value.doctype,
      );
    }
    final parentTable = await metaDao.tableNameFor(row.doctype);
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
    final parentTable = await metaDao.tableNameFor(row.doctype);
    final currentRows = await db.query(
      parentTable,
      where: 'mobile_uuid = ?',
      whereArgs: [row.mobileUuid],
      limit: 1,
    );
    if (currentRows.isEmpty) {
      await outboxDao.markConflict(
        row.id,
        errorMessage: 'TimestampMismatch with no docs__ row to merge into',
      );
      return;
    }
    final currentRow = currentRows.first;
    final docServerName = currentRow['server_name'] as String?;
    if (docServerName == null) {
      await outboxDao.markConflict(
        row.id,
        errorMessage: 'TimestampMismatch on a row with no server_name',
      );
      return;
    }
    // Base for ThreeWayMerge: the pre-edit snapshot captured by
    // OfflineRepository.saveDocument and stored on docs__.push_base_payload.
    // Without it, the merge cannot distinguish "user left null" from
    // "user explicitly cleared" — every null field would silently fall
    // to the server value and a legacy row with many null columns would
    // lose the user's actual edits. Safer: surface to the user as a
    // conflict (Spec §5.5 — review item #6 claim 2).
    final basePayload = currentRow['push_base_payload'] as String?;
    if (basePayload == null || basePayload.isEmpty) {
      await outboxDao.markConflict(
        row.id,
        errorMessage:
            'TimestampMismatch with no push_base_payload — manual resolution required',
      );
      return;
    }
    final fresh = await serverFetcher(row.doctype, docServerName);
    final base = Map<String, Object?>.from(jsonDecode(basePayload) as Map);
    final merged = ThreeWayMerge.mergeFields(
      base: base,
      ours: Map<String, Object?>.from(currentRow),
      theirs: Map<String, Object?>.from(fresh),
    );

    // Persist merged values + the server's modified into the local row.
    // The merged map may contain server-only keys (`name`, `creation`,
    // `owner`, etc.) that aren't columns on `docs__<doctype>` — filter
    // against the actual table schema to avoid SQLITE_ERROR.
    final tableCols = (await db.rawQuery(
      'PRAGMA table_info($parentTable)',
    )).map((r) => r['name'] as String).toSet();
    final mergedForUpdate = <String, Object?>{};
    for (final entry in merged.entries) {
      if (tableCols.contains(entry.key)) {
        mergedForUpdate[entry.key] = entry.value;
      }
    }
    mergedForUpdate['modified'] = fresh['modified'];
    mergedForUpdate['mobile_uuid'] = row.mobileUuid;

    // Slim outbox no longer carries `retry_count` or `payload`; the
    // retry counter lives on docs__.sync_attempts (already incremented
    // in `_dispatchOnce`) and the merge base lives on
    // docs__.push_base_payload.
    //
    // Write `in_flight` directly (PR#36 round-2 M2) — NOT `pending`.
    // We recurse into `_process` below, which immediately calls
    // `markInFlight`, but the gap between this txn's commit and that
    // `markInFlight` is observable: a concurrent `runOnce` could see
    // `state='pending'` via `findByState(pending)` and double-dispatch
    // the same row. Going straight to `in_flight` closes the window;
    // the recursive `markInFlight` becomes an idempotent no-op.
    final outboxUpdate = <String, Object?>{
      'state': OutboxState.inFlight.wireName,
    };

    // Route both writes through the per-doctype WriteQueue when wired so
    // they share a transaction with concurrent writeback activity. Falls
    // back to a single `db.transaction` when no resolver is provided —
    // never two bare `db.update` calls: a crash between them would leave
    // docs__ merged but the outbox row still `in_flight`, which would
    // mis-assemble the payload on the next drain.
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
      await db.transaction((txn) async {
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
    }

    final updated = await outboxDao.findById(row.id);
    if (updated != null) {
      await _process(updated, mergeAttempted: true);
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
        map[f.fieldname!] = ChildTableInfo(f.options!, childMeta);
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

  /// Reads the row's `docs__<doctype>` mirror (and child rows) and returns
  /// every `<field>__is_local=1` value — these are mobile_uuids of
  /// upstream targets that must land before this row can be pushed. Used
  /// by [runOnce] to drive [TierComputer] so a parent INSERT lands in an
  /// earlier tier than its dependents instead of racing in tier 0.
  ///
  /// Failures (missing table, meta resolve error) return an empty list —
  /// the row falls through to whatever the default [dependencyScanner]
  /// returns. Worst case the row gets an extra retry as `blocked` rather
  /// than crashing the drain.
  Future<List<String>> _scanLocalDepsFor(OutboxRow row) async {
    final tableName = normalizeDoctypeTableName(row.doctype);
    if (!await sqliteTableExists(db, tableName)) return const [];
    final List<Map<String, Object?>> parentRows;
    try {
      parentRows = await db.query(
        tableName,
        where: 'mobile_uuid = ?',
        whereArgs: [row.mobileUuid],
        limit: 1,
      );
    } on DatabaseException {
      return const [];
    }
    if (parentRows.isEmpty) return const [];
    final parentData = parentRows.first;

    final DocTypeMeta meta;
    try {
      meta = await metaResolver(row.doctype);
    } catch (e, st) {
      sdkLog('PushEngine: metaResolver(${row.doctype}) failed — $e\n$st');
      return const [];
    }

    final deps = <String>{};
    _collectLocalLinkValues(parentData, meta, deps);

    for (final f in meta.fields) {
      if (f.fieldtype != 'Table' && f.fieldtype != 'Table MultiSelect') {
        continue;
      }
      final childDoctype = f.options;
      if (childDoctype == null || childDoctype.isEmpty) continue;
      final childTable = normalizeDoctypeTableName(childDoctype);
      if (!await sqliteTableExists(db, childTable)) continue;
      final List<Map<String, Object?>> childRows;
      try {
        childRows = await db.query(
          childTable,
          where: 'parent_uuid = ?',
          whereArgs: [row.mobileUuid],
        );
      } on DatabaseException {
        continue;
      }
      if (childRows.isEmpty) continue;
      final DocTypeMeta childMeta;
      try {
        childMeta = await childMetaResolver(childDoctype);
      } catch (e, st) {
        sdkLog('PushEngine: childMetaResolver($childDoctype) failed — $e\n$st');
        continue;
      }
      for (final cr in childRows) {
        _collectLocalLinkValues(cr, childMeta, deps);
      }
    }

    deps.remove(row.mobileUuid);
    return deps.toList();
  }

  static void _collectLocalLinkValues(
    Map<String, Object?> row,
    DocTypeMeta meta,
    Set<String> out,
  ) {
    for (final f in meta.fields) {
      final name = f.fieldname;
      if (name == null) continue;
      if (f.fieldtype != 'Link' && f.fieldtype != 'Dynamic Link') continue;
      final v = row[name]?.toString();
      if (v == null || v.isEmpty) continue;
      // Treat a Link value as a local dependency when the form flagged it
      // (`__is_local == 1`) OR when the value is shaped like a mobile_uuid.
      // The shape check mirrors [UuidRewriter] so tiering and rewriting
      // agree: without it, a UUID-valued Link populated by a non-picker
      // path (no `__is_local`) is invisible to the dependency scan, lands
      // in the same tier as its parent, and races — exactly the
      // "not synced in order" symptom.
      final flagged = (row['${name}__is_local'] as int?) == 1;
      if (flagged || looksLikeMobileUuid(v)) out.add(v);
    }
  }
}
