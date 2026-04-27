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
/// Spec §5.5. Child tables are NOT merged here — when a parent is dirty,
/// the local list is authoritative; engine handles that at a higher
/// layer.
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

  static bool _eq(Object? a, Object? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    return a == b;
  }
}
