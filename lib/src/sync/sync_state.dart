import 'cursor.dart';

/// Per-doctype pull progress snapshot. All fields immutable.
class DoctypeSyncState {
  final int pulledCount;
  final int? lastPageSize;
  final bool hasMore;
  final bool deferred;
  final Cursor? lastOkCursor;
  final String? note;
  final DateTime? startedAt;
  final DateTime? completedAt;

  const DoctypeSyncState({
    this.pulledCount = 0,
    this.lastPageSize,
    this.hasMore = false,
    this.deferred = false,
    this.lastOkCursor,
    this.note,
    this.startedAt,
    this.completedAt,
  });
}

/// Counts of outbox/attachment rows by state. Used by status widgets and
/// the SyncErrorsScreen.
class QueueSummary {
  final int pending;
  final int inFlight;
  final int failed;
  final int conflict;
  final int blocked;
  final int attachments;

  const QueueSummary({
    this.pending = 0,
    this.inFlight = 0,
    this.failed = 0,
    this.conflict = 0,
    this.blocked = 0,
    this.attachments = 0,
  });

  static const empty = QueueSummary();
}

/// Last-error summary surfaced to the UI (a single most-recent error;
/// detailed list lives in the outbox).
class SyncErrorSummary {
  final String code;
  final String message;
  final DateTime at;

  const SyncErrorSummary({
    required this.code,
    required this.message,
    required this.at,
  });
}

/// Composable sync-state snapshot. The flags overlap freely (pull + push
/// can both be active at the same time); UI widgets pick a priority label
/// using their own `priorityLabel(snapshot)` helper.
class SyncState {
  final bool isOnline;
  final bool isInitialSync;
  final bool isPulling;
  final bool isPushing;
  final bool isUploading;
  final bool isPaused;
  final Map<String, DoctypeSyncState> perDoctype;
  final QueueSummary queue;
  final SyncErrorSummary? lastError;
  final DateTime? lastSyncAt;

  const SyncState({
    required this.isOnline,
    required this.isInitialSync,
    required this.isPulling,
    required this.isPushing,
    required this.isUploading,
    required this.isPaused,
    required this.perDoctype,
    required this.queue,
    this.lastError,
    this.lastSyncAt,
  });

  static const SyncState initial = SyncState(
    isOnline: false,
    isInitialSync: false,
    isPulling: false,
    isPushing: false,
    isUploading: false,
    isPaused: false,
    perDoctype: <String, DoctypeSyncState>{},
    queue: QueueSummary.empty,
  );

  SyncState copyWith({
    bool? isOnline,
    bool? isInitialSync,
    bool? isPulling,
    bool? isPushing,
    bool? isUploading,
    bool? isPaused,
    Map<String, DoctypeSyncState>? perDoctype,
    QueueSummary? queue,
    SyncErrorSummary? lastError,
    DateTime? lastSyncAt,
  }) {
    return SyncState(
      isOnline: isOnline ?? this.isOnline,
      isInitialSync: isInitialSync ?? this.isInitialSync,
      isPulling: isPulling ?? this.isPulling,
      isPushing: isPushing ?? this.isPushing,
      isUploading: isUploading ?? this.isUploading,
      isPaused: isPaused ?? this.isPaused,
      perDoctype: perDoctype ?? this.perDoctype,
      queue: queue ?? this.queue,
      lastError: lastError ?? this.lastError,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }

  SyncState updatePerDoctype(String doctype, DoctypeSyncState s) {
    final next = Map<String, DoctypeSyncState>.from(perDoctype);
    next[doctype] = s;
    return copyWith(perDoctype: next);
  }
}
