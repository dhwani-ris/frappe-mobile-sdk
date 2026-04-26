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
  final RunFn runPull;
  final RunFn runPush;

  SyncController({
    required this.outboxDao,
    required this.notifier,
    required this.runPull,
    required this.runPush,
  });

  SyncState get state => notifier.value;
  Stream<SyncState> get state$ => notifier.stream;

  /// Pull then push. Used by `Sync now` button + connectivity-restore
  /// hooks. Caller can run the two phases independently if it has its
  /// own scheduling.
  Future<void> syncNow() async {
    await runPull();
    await runPush();
  }

  Future<void> pause() async {
    notifier.value = notifier.value.copyWith(isPaused: true);
  }

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

  /// Re-queue every error/blocked/conflict row sorted by Spec §7.4
  /// priority, then run a single push drain. [filterDoctypes] limits
  /// the operation to a doctype subset (used by the per-doctype
  /// `Retry` action in SyncErrorsScreen).
  Future<void> retryAll({List<String>? filterDoctypes}) async {
    final all = [
      ...await outboxDao.findByState(OutboxState.failed),
      ...await outboxDao.findByState(OutboxState.conflict),
      ...await outboxDao.findByState(OutboxState.blocked),
    ];
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
  Future<List<OutboxRow>> pendingErrors() async {
    final rows = <OutboxRow>[];
    rows.addAll(await outboxDao.findByState(OutboxState.failed));
    rows.addAll(await outboxDao.findByState(OutboxState.conflict));
    rows.addAll(await outboxDao.findByState(OutboxState.blocked));
    return rows;
  }

  /// Resolves a conflicted row.
  /// - [pullAndOverwriteLocal]: marks the row done with its current
  ///   `server_name`. The next pull picks up the server snapshot;
  ///   local edits are discarded.
  /// - [keepLocalAndRetry]: flips the row back to pending so the push
  ///   engine runs ThreeWayMerge again with a fresh server snapshot.
  Future<void> resolveConflict({
    required int outboxId,
    required ConflictAction action,
  }) async {
    final row = await outboxDao.findById(outboxId);
    if (row == null) return;
    if (action == ConflictAction.pullAndOverwriteLocal) {
      await outboxDao.markDone(outboxId, serverName: row.serverName ?? '');
    } else {
      await outboxDao.resetToPending(outboxId);
      await runPush();
    }
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
      } catch (_) {
        blocked = const {};
      }
    }
    return DeleteCascadePlan(
      rootOutboxId: outboxId,
      blockedBy: blocked,
    );
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
