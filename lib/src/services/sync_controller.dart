import 'dart:async';
import 'dart:convert';

import '../database/daos/outbox_dao.dart';
import '../models/outbox_row.dart';
import '../sync/sync_state.dart';
import '../sync/sync_state_notifier.dart';
import 'retry_priority.dart';

/// Choice the user makes on a conflict row in the SyncErrorsScreen.
/// `pullAndOverwriteLocal` accepts the server snapshot (local edits
/// discarded); `keepLocalAndRetry` re-queues the row so the push engine
/// re-fetches the server version and runs ThreeWayMerge again.
enum ConflictAction { pullAndOverwriteLocal, keepLocalAndRetry }

typedef RunFn = Future<void> Function();

/// Pull runner — returns the set of doctypes the engine deferred because
/// a push was active for them. Caller re-runs [RunPullForFn] for this
/// subset after the push completes (SIG-2).
typedef RunPullFn = Future<Set<String>> Function();

/// Targeted re-pull for a specific doctype subset. Wraps
/// `PullEngine.run(closure)` over a closure scoped to [doctypes].
typedef RunPullForFn = Future<void> Function(Set<String> doctypes);

/// Fetches a single document snapshot from the server. Throws on any
/// failure (404, 5xx, network) — the wired implementation is
/// `client.doctype.getByName`, whose contract throws `ApiException` on
/// non-2xx responses (`rest_helper.dart:245`). Callers do NOT receive
/// `null` on missing rows; that case surfaces as a thrown 404.
typedef FetchSingleDocFn =
    Future<Map<String, dynamic>> Function(String doctype, String serverName);

/// Applies a single server-side document snapshot to the local mirror.
/// The wired implementation builds parentMeta + childMetasByFieldname
/// inline (using the same MetaResolverFn that PullEngine uses) and calls
/// `PullApply.applyPage(... rows: [doc])`.
typedef ApplySingleDocFn =
    Future<void> Function(String doctype, Map<String, dynamic> doc);

/// Public imperative surface for sync. Spec §9.3.
///
/// The controller is a thin facade over [OutboxDao], [SyncStateNotifier],
/// and the wired pull/push runners. It owns no business logic — all
/// scheduling, dependency tracking, and retry semantics live in
/// PullEngine / PushEngine. The controller's job is to:
/// - Provide a consumer-facing API (`syncNow`, `retry`, `retryAll`,
///   `pause/resume`, `resolveConflict`).
/// - Re-prioritise outbox rows for `Retry all` per Spec §7.4.
/// - Surface the `SyncState` stream the UI subscribes to.
///
/// `runPull` and `runPush` are injected so the controller is decoupled
/// from PullEngine / PushEngine for tests; in production the SDK wires
/// them to `PullEngine.run(closure)` and `PushEngine.runOnce()`.
class SyncController {
  final OutboxDao outboxDao;
  final SyncStateNotifier notifier;
  final RunPullFn runPull;
  final RunFn runPush;
  final RunPullForFn runPullForDoctypes;
  final FetchSingleDocFn fetchSingleDoc;
  final ApplySingleDocFn applySingleDoc;

  /// Optional. Resolves a `server_name` for a given `(doctype, mobile_uuid)`
  /// by reading `docs__<doctype>`. Used by [resolveConflict] because the
  /// slim outbox no longer carries `server_name` directly. When null,
  /// `resolveConflict` cannot drive a server fetch — `pullAndOverwriteLocal`
  /// falls back to the "INSERT never reached the server" branch.
  final Future<String?> Function(String doctype, String mobileUuid)?
  resolveServerName;

  SyncController({
    required this.outboxDao,
    required this.notifier,
    required this.runPull,
    required this.runPush,
    required this.runPullForDoctypes,
    required this.fetchSingleDoc,
    required this.applySingleDoc,
    this.resolveServerName,
  });

  SyncState get state => notifier.value;
  Stream<SyncState> get state$ => notifier.stream;

  /// Pull then push. Doctypes deferred during the pull (because a push
  /// was active for them) are re-pulled after the push completes — SIG-2.
  /// Used by `Sync now` button + connectivity-restore hooks. No-ops while
  /// paused.
  Future<void> syncNow() async {
    if (notifier.value.isPaused) return;
    Set<String> deferred = const <String>{};
    try {
      deferred = await runPull();
    } catch (e, st) {
      // Pull failed — runPush still runs so dirty rows can drain even
      // when the server-read side has issues. PullEngine.run's own
      // finally already resets `isPulling`. syncNow is best-effort:
      // surface via SyncState.lastError, not by throwing.
      // ignore: avoid_print
      print('SyncController.syncNow: runPull failed — $e\n$st');
    }
    try {
      await runPush();
    } catch (e, st) {
      // PushEngine.runOnce wraps its body in try/finally, so isPushing
      // is already reset. Same best-effort contract as the pull above.
      // ignore: avoid_print
      print('SyncController.syncNow: runPush failed — $e\n$st');
    }
    if (deferred.isNotEmpty) {
      try {
        await runPullForDoctypes(deferred);
      } catch (e, st) {
        // SIG-2 deferred re-pull is best-effort; the doctypes will be
        // picked up on the next syncNow when push activity has settled.
        // ignore: avoid_print
        print(
          'SyncController.syncNow: runPullForDoctypes($deferred) failed — '
          '$e\n$st',
        );
      }
    }
  }

  /// Prevents [syncNow] from starting new pull/push cycles. In-flight
  /// operations already running via [runPull]/[runPush] are not interrupted.
  Future<void> pause() async {
    notifier.value = notifier.value.copyWith(isPaused: true);
  }

  /// Re-enables [syncNow] after a [pause].
  Future<void> resume() async {
    notifier.value = notifier.value.copyWith(isPaused: false);
  }

  /// UI-facing cancel for the initial-sync blocking screen. The pull
  /// itself is owned by whoever called `runPull`; this only flips the
  /// `isInitialSync` flag in SyncState so the UI dismisses.
  Future<void> cancelInitialSync() async {
    notifier.value = notifier.value.copyWith(isInitialSync: false);
  }

  /// Re-queue a single failed/blocked/conflict row and run a single
  /// push drain. No-op for `done` rows.
  Future<void> retry(int outboxId) async {
    final row = await outboxDao.findById(outboxId);
    if (row == null) return;
    if (row.state == OutboxState.done) return;
    await outboxDao.resetToPending(outboxId);
    await runPush();
  }

  /// All outbox rows in any "actionable" terminal state — failed,
  /// conflict, or blocked. These are the buckets surfaced to the user as
  /// errors and the rows that [retryAll] re-queues. Shared by `retryAll`
  /// and `pendingErrors` so the set of "error" states stays uniform.
  Future<List<OutboxRow>> _allActionableRows() async {
    return [
      ...await outboxDao.findByState(OutboxState.failed),
      ...await outboxDao.findByState(OutboxState.conflict),
      ...await outboxDao.findByState(OutboxState.blocked),
    ];
  }

  /// Re-queue every error/blocked/conflict row sorted by Spec §7.4
  /// priority, then run a single push drain. [filterDoctypes] limits
  /// the operation to a doctype subset (used by the per-doctype
  /// `Retry` action in SyncErrorsScreen).
  Future<void> retryAll({List<String>? filterDoctypes}) async {
    final all = await _allActionableRows();
    final filtered = filterDoctypes == null
        ? all
        : all.where((r) => filterDoctypes.contains(r.doctype)).toList();
    final sorted = RetryPriority.sort(filtered);
    for (final r in sorted) {
      await outboxDao.resetToPending(r.id);
    }
    await runPush();
  }

  /// All rows currently in failed / conflict / blocked. Used by
  /// SyncErrorsScreen and the `Retry all` button's progress display.
  Future<List<OutboxRow>> pendingErrors() => _allActionableRows();

  /// Resolves a conflicted row.
  /// - [pullAndOverwriteLocal]: fetches the current server snapshot, applies
  ///   it to the local mirror, then marks the outbox row done. Blocking —
  ///   the dialog awaits this future before dismissing, so the user
  ///   returning to the list view sees server values immediately. Any
  ///   failure (network, 404, 5xx) propagates to the caller; the outbox
  ///   row stays in `conflict` so the user can retry. NO silent deletion
  ///   semantics — a 404 is treated as a fetch failure, not as "server
  ///   deleted this row".
  /// - [keepLocalAndRetry]: flips the row back to pending so the push
  ///   engine runs ThreeWayMerge again with a fresh server snapshot.
  Future<void> resolveConflict({
    required int outboxId,
    required ConflictAction action,
  }) async {
    final row = await outboxDao.findById(outboxId);
    if (row == null) return;
    if (action == ConflictAction.pullAndOverwriteLocal) {
      // Slim outbox: `server_name` lives on docs__<doctype>; resolve via
      // the injected callback. Fall back to null when the SDK didn't
      // wire one (early test harnesses).
      final serverName = resolveServerName == null
          ? null
          : await resolveServerName!(row.doctype, row.mobileUuid);
      if (serverName == null || serverName.isEmpty) {
        // INSERT that never reached the server — there is nothing to
        // fetch. Close the outbox row; per-doctype row stays as the
        // user's local copy. NOT a "treat 404 as deleted" path.
        await outboxDao.markDone(outboxId, serverName: '');
        return;
      }
      final snapshot = await fetchSingleDoc(row.doctype, serverName);
      await applySingleDoc(row.doctype, snapshot);
      await outboxDao.markDone(outboxId, serverName: serverName);
    } else {
      await outboxDao.resetToPending(outboxId);
      await runPush();
    }
  }

  /// Confirms the cascade plan produced by [previewDeleteCascade] and
  /// resets the root row to pending so the push engine retries the
  /// delete on the next drain. No-op if the row is not in
  /// `failed(LINK_EXISTS)`.
  Future<void> acceptDeleteCascade(int outboxId) async {
    final row = await outboxDao.findById(outboxId);
    if (row == null) return;
    if (row.errorCode != ErrorCode.LINK_EXISTS) return;
    await outboxDao.resetToPending(outboxId);
    await runPush();
  }

  /// Parses the structured `LinkExistsError` payload stored in
  /// `outbox.error_message` and returns a plan describing the
  /// dependent docs the user would have to delete to unblock this
  /// outbox row. Returns null if the row isn't in
  /// `failed(LINK_EXISTS)`. UI surface is `DeleteCascadePrompt`.
  Future<DeleteCascadePlan?> previewDeleteCascade(int outboxId) async {
    final row = await outboxDao.findById(outboxId);
    if (row == null) return null;
    if (row.errorCode != ErrorCode.LINK_EXISTS) return null;
    Map<String, List<String>> blocked = const {};
    final raw = row.errorMessage;
    if (raw != null && raw.isNotEmpty) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is Map && parsed['linked'] is Map) {
          final m = parsed['linked'] as Map;
          blocked = m.map(
            (k, v) => MapEntry(
              k as String,
              (v as List).map((e) => e.toString()).toList(),
            ),
          );
        }
      } catch (e, st) {
        // ignore: avoid_print
        print(
          'SyncController.previewDeleteCascade: blockedBy parse failed — $e\n$st',
        );
        blocked = const {};
      }
    }
    return DeleteCascadePlan(rootOutboxId: outboxId, blockedBy: blocked);
  }
}

/// Output of [SyncController.previewDeleteCascade] — the user-facing
/// data behind the `DeleteCascadePrompt` widget. `blockedBy` is a map
/// of dependent-doctype → list of server names that link to the row
/// the user is trying to delete.
class DeleteCascadePlan {
  final int rootOutboxId;
  final Map<String, List<String>> blockedBy;
  const DeleteCascadePlan({
    required this.rootOutboxId,
    required this.blockedBy,
  });
}
