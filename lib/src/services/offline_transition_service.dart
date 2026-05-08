import 'dart:async';

import '../database/app_database.dart';
import 'sync_service.dart';

/// Sealed hierarchy of states emitted on the transition stream.
sealed class OfflineTransitionState {
  const OfflineTransitionState();
}

class TransitionIdle extends OfflineTransitionState {
  const TransitionIdle();
}

class TransitionDraining extends OfflineTransitionState {
  final int totalRecords;
  final int drainedRecords;
  const TransitionDraining({
    required this.totalRecords,
    required this.drainedRecords,
  });
}

class TransitionDrainFailed extends OfflineTransitionState {
  final int remainingDirty;
  final int remainingFailedAttachments;
  final String? lastError;
  const TransitionDrainFailed({
    required this.remainingDirty,
    required this.remainingFailedAttachments,
    this.lastError,
  });
}

class TransitionWipingTables extends OfflineTransitionState {
  const TransitionWipingTables();
}

class TransitionCompleted extends OfflineTransitionState {
  const TransitionCompleted();
}

/// Drives the offline → online transition. Owns its own broadcast stream;
/// callers subscribe via [stream]. Public surface: [runDrainAndWipe],
/// [retry], [forceExit].
///
/// Spec §7.
class OfflineTransitionService {
  final AppDatabase _db;
  final Future<SyncService> Function() _drainSyncFactory;
  final Future<int> Function() _residueCounter;

  final StreamController<OfflineTransitionState> _ctrl =
      StreamController<OfflineTransitionState>.broadcast();
  Completer<void>? _userActionCompleter;
  OfflineTransitionState _last = const TransitionIdle();
  bool _forceExited = false;

  OfflineTransitionService({
    required AppDatabase database,
    required Future<SyncService> Function() drainSyncFactory,
    required Future<int> Function() residueCounter,
  }) : _db = database,
       _drainSyncFactory = drainSyncFactory,
       _residueCounter = residueCounter;

  Stream<OfflineTransitionState> get stream => _ctrl.stream;

  /// The most recent state emitted (or [TransitionIdle] if none yet).
  /// Synchronous; useful for the `AppGuard` initial frame.
  OfflineTransitionState get current => _last;

  void _emit(OfflineTransitionState state) {
    _last = state;
    if (!_ctrl.isClosed) _ctrl.add(state);
  }

  /// Runs drain → wipe → completed. If drain fails, parks in
  /// [TransitionDrainFailed] and awaits [retry] or [forceExit].
  /// Returns once [TransitionCompleted] is reached.
  ///
  /// [progressInterval] is the cadence at which residue is re-counted
  /// while [SyncService.pushSync] runs, so the UI's Draining state
  /// shows a live `drainedRecords` count. Defaults to 500ms; tests
  /// override to 0 (manual ticks) for determinism.
  Future<void> runDrainAndWipe({
    Duration progressInterval = const Duration(milliseconds: 500),
  }) async {
    _forceExited = false;
    while (true) {
      final initialResidue = await _residueCounter();
      _emit(
        TransitionDraining(totalRecords: initialResidue, drainedRecords: 0),
      );

      String? lastError;
      Timer? progressTimer;
      var lastDrained = 0;
      var probeInFlight = false;
      try {
        final sync = await _drainSyncFactory();
        // Periodic progress probe so the UI's drained-count actually
        // moves during the drain. pushSync() is a single async call
        // with no built-in progress events, so we re-run the residue
        // counter on a timer and emit when it advances. Best-effort:
        // any probe failure (closed stream, transient DB lock) is
        // swallowed — the drain itself is still authoritative.
        progressTimer = Timer.periodic(progressInterval, (_) async {
          if (probeInFlight || _ctrl.isClosed) return;
          probeInFlight = true;
          try {
            final remaining = await _residueCounter();
            final drained = initialResidue - remaining;
            if (drained > lastDrained) {
              lastDrained = drained;
              _emit(
                TransitionDraining(
                  totalRecords: initialResidue,
                  drainedRecords: drained,
                ),
              );
            }
          } catch (e, st) {
            // Probe is best-effort — the drain itself is authoritative.
            // Log so a misconfigured residueCounter doesn't fail silently.
            // ignore: avoid_print
            print('OfflineTransitionService: progress probe failed — $e\n$st');
          } finally {
            probeInFlight = false;
          }
        });
        await sync.pushSync();
      } catch (e, st) {
        // ignore: avoid_print
        print('OfflineTransitionService: pushSync drain failed — $e\n$st');
        lastError = e.toString();
      } finally {
        progressTimer?.cancel();
      }

      final remainingResidue = await _residueCounter();
      if (remainingResidue == 0) {
        _emit(const TransitionWipingTables());
        await _db.wipeOfflineDocumentTables();
        _emit(const TransitionCompleted());
        return;
      }

      _emit(
        TransitionDrainFailed(
          remainingDirty: remainingResidue,
          remainingFailedAttachments: 0,
          lastError: lastError,
        ),
      );

      _userActionCompleter = Completer<void>();
      await _userActionCompleter!.future;
      _userActionCompleter = null;
      // forceExit() already handled wipe + emit(Completed) — short-circuit
      // out of the loop instead of re-attempting drain on already-wiped state.
      if (_forceExited) return;
      // Otherwise: retry path re-enters the while.
    }
  }

  /// Retries the drain after [TransitionDrainFailed]. No-op if no
  /// failure is pending.
  void retry() {
    final c = _userActionCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Force-exits: drops tables unconditionally and emits
  /// [TransitionCompleted]. Used when the user accepts data loss.
  Future<void> forceExit() async {
    _emit(const TransitionWipingTables());
    await _db.wipeOfflineDocumentTables();
    _emit(const TransitionCompleted());
    _forceExited = true;
    final c = _userActionCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> dispose() async {
    final c = _userActionCompleter;
    if (c != null && !c.isCompleted) c.complete();
    await _ctrl.close();
  }
}
