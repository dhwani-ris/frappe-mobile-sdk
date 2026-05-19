/// Field-level last-write-wins merge for the conflict path.
///
/// Inputs:
/// - `base`: snapshot the SDK held when the user started editing (the
///   `modified` timestamp captured in the outbox row's payload).
/// - `ours`: current `docs__<doctype>` row — what the user actually has.
/// - `theirs`: freshly-fetched server snapshot.
///
/// Rule: for every field, if `ours != base` the user changed it locally
/// → prefer ours. Otherwise prefer theirs (the server moved while we
/// were idle). Fields present on only one side flow through.
///
/// Spec §5.5.
///
/// ## Child tables are intentionally NOT merged here
///
/// When a parent is dirty, the local child list is treated as
/// authoritative — the engine does not call this method on child rows
/// and the pull path (`PullApply`) shields locally-dirty parents (and
/// their children) from the server snapshot via the
/// `_locallyDirtyStatuses` gate.
///
/// **Why row-level merge isn't implemented:**
///   1. Children have no stable identity until the server assigns one.
///      Matching `(parent_uuid, parentfield, idx)` works for re-ordering
///      but breaks under insert/delete — a server-side insert at idx=0
///      shifts every row down, so the position-based merge would treat
///      every row as edited.
///   2. Frappe's `idx` semantics overwrite `idx=0 → 1` (`base_document.
///      append`), so client-supplied 0-based indices don't round-trip.
///   3. The product decision is that dirty children "win" rather than
///      surface a granular merge dialog — fewer false positives, no UI
///      affordance needed.
///
/// **If a future iteration needs row-level child merge**, the load-
/// bearing pieces are:
///   - extend `Custom Field` install in `mobile_control` to ship
///     `mobile_uuid` onto every child DocType (already wired for parents)
///     so children gain stable identity across server round-trips;
///   - drive matching from `mobile_uuid → server_name → position` (same
///     priority used by `ResponseWriteback` and `PullApply`);
///   - apply [mergeFields] cell-wise per matched pair and pass unmatched
///     rows through as additions/deletions.
///
/// Until then: a locally-dirty parent's child list is authoritative; on
/// the conflict screen the user picks parent-level OURS/THEIRS and the
/// child list goes with it.
class ThreeWayMerge {
  static Map<String, Object?> mergeFields({
    required Map<String, Object?> base,
    required Map<String, Object?> ours,
    required Map<String, Object?> theirs,
  }) {
    final keys = {...base.keys, ...ours.keys, ...theirs.keys};
    final out = <String, Object?>{};
    for (final k in keys) {
      final b = base[k];
      final o = ours.containsKey(k) ? ours[k] : b;
      final t = theirs.containsKey(k) ? theirs[k] : b;
      final localChanged = !_eq(o, b);
      out[k] = localChanged ? o : t;
    }
    return out;
  }

  /// Deep equality. Dart's default `Object.==` is identity for `List`
  /// and `Map`, which would treat every decoded-JSON list/map field as
  /// locally-changed and silently discard server updates (PR#36 round-2
  /// H7). Scalars still use `==`; container types recurse.
  static bool _eq(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_eq(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k)) return false;
        if (!_eq(a[k], b[k])) return false;
      }
      return true;
    }
    return a == b;
  }
}
