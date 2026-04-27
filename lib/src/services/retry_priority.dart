import '../models/outbox_row.dart';

/// Reorders outbox rows for `Retry all` per Spec §7.4.
///
/// Priority (1 highest, 7 lowest):
/// 1. `state=failed AND error_code IN (NETWORK, TIMEOUT)` — transient.
/// 2. `state=blocked` — releases dependents on parent success.
/// 3. `state=conflict` — often succeeds after auto-merge retry.
/// 4. `state=failed AND error_code=LINK_EXISTS` — succeeds only after
///    dependents are deleted.
/// 5. `state=failed AND error_code IN (VALIDATION, MANDATORY)` — usually
///    requires user fix.
/// 6. `state=failed AND error_code=PERMISSION_DENIED` — needs role change.
/// 7. `state=failed AND error_code IN (UNKNOWN, TIMESTAMP_MISMATCH, null)`.
///
/// Within a bucket: ascending `created_at` (oldest first) — matches the
/// natural FIFO of outbox insertion and keeps tier topology intact when
/// the engine consumes the result.
class RetryPriority {
  static List<OutboxRow> sort(List<OutboxRow> rows) {
    final copy = [...rows];
    copy.sort((a, b) {
      final pa = _priority(a);
      final pb = _priority(b);
      final cmp = pa.compareTo(pb);
      if (cmp != 0) return cmp;
      return a.createdAt.compareTo(b.createdAt);
    });
    return copy;
  }

  /// Lower = earlier in dispatch order.
  static int _priority(OutboxRow r) {
    if (r.state == OutboxState.failed) {
      switch (r.errorCode) {
        case ErrorCode.NETWORK:
        case ErrorCode.TIMEOUT:
          return 1;
        case ErrorCode.LINK_EXISTS:
          return 4;
        case ErrorCode.VALIDATION:
        case ErrorCode.MANDATORY:
          return 5;
        case ErrorCode.PERMISSION_DENIED:
          return 6;
        case ErrorCode.UNKNOWN:
        case ErrorCode.TIMESTAMP_MISMATCH:
        case null:
          return 7;
      }
    }
    if (r.state == OutboxState.blocked) return 2;
    if (r.state == OutboxState.conflict) return 3;
    return 7;
  }
}
