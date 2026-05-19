import '../models/outbox_row.dart';

typedef DependenciesForRowFn = List<String> Function(OutboxRow row);

/// Groups pending outbox rows into dispatch tiers based on
/// mobile_uuid → mobile_uuid dependency edges.
///
/// Tier 0 contains rows whose payloads don't reference any *other* pending
/// row's `mobile_uuid`. Tier k contains rows whose dependencies are all in
/// tiers `< k`. Each tier dispatches concurrently through PushPool; tiers
/// are processed in order so a parent INSERT lands before any dependent
/// child INSERT.
///
/// **Cycle safety.** If two rows depend on each other (impossible in the
/// real outbox model — INSERT can't reference an unsynced doc that
/// references it back — but possible in misconstructed test data),
/// remaining rows are emitted in a final tier after `rows.length + 1`
/// iterations. The engine then dispatches them anyway; they will fail
/// upstream-resolution and be marked `blocked`, surfacing the issue.
///
/// Self-references (`u1 depends on u1`) are silently ignored.
class TierComputer {
  static List<List<OutboxRow>> compute({
    required List<OutboxRow> rows,
    required DependenciesForRowFn dependenciesForRow,
  }) {
    final sorted = [...rows]
      ..sort((a, b) {
        final cmp = a.createdAt.compareTo(b.createdAt);
        return cmp != 0 ? cmp : a.id.compareTo(b.id);
      });
    final pendingUuids = sorted.map((r) => r.mobileUuid).toSet();
    final settled = <String>{};
    final tiers = <List<OutboxRow>>[];
    var remaining = [...sorted];
    var iter = 0;
    final maxIter = sorted.length + 1;
    while (remaining.isNotEmpty && iter < maxIter) {
      iter++;
      final thisTier = <OutboxRow>[];
      final nextRemaining = <OutboxRow>[];
      for (final r in remaining) {
        final deps = dependenciesForRow(r)
            .where((u) => pendingUuids.contains(u) && u != r.mobileUuid)
            .toSet();
        if (deps.every(settled.contains)) {
          thisTier.add(r);
        } else {
          nextRemaining.add(r);
        }
      }
      if (thisTier.isEmpty) {
        // Cycle / stuck — emit remaining in a final tier so they aren't
        // lost. Engine treats them like any other tier; upstream-resolve
        // will mark them blocked.
        tiers.add(nextRemaining);
        return tiers;
      }
      tiers.add(thisTier);
      for (final r in thisTier) {
        settled.add(r.mobileUuid);
      }
      remaining = nextRemaining;
    }
    return tiers;
  }
}
