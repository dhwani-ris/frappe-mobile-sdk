import '../models/closure_result.dart';
import '../models/dep_graph.dart';
import '../models/doc_type_meta.dart';
import 'dependency_graph_builder.dart';

typedef MetaFetcher = Future<DocTypeMeta> Function(String doctype);

class ClosureBuilder {
  /// BFS across Link + Table + Table MultiSelect edges from entry points.
  /// Skips Dynamic Link targets (resolved at runtime). Cycles safe (visited set).
  ///
  /// Drains the queue level-by-level (Kahn-style) with bounded parallel
  /// [metaFetcher] calls inside each level. The dependency relation only
  /// flows across levels, so within one level metas can be fetched
  /// concurrently. [metaConcurrency] caps in-flight requests — kept small
  /// (4) to stay friendly to low-end mobile CPUs and avoid saturating
  /// HTTP/1.1 connection pools.
  static Future<ClosureResult> build({
    required List<String> entryPoints,
    required MetaFetcher metaFetcher,
    int metaConcurrency = 4,
  }) async {
    final outgoingByDt = <String, DepGraph>{};
    final tierMap = <String, int>{};
    final incoming = <String, List<DepEdge>>{};
    final childDoctypes = <String>{};
    final warnings = <String>[];

    // Frontier of doctypes to fetch at the current BFS level. Seeded
    // with entry points; refilled at the end of each level with the
    // newly-discovered targets that haven't been visited yet.
    var frontier = <_QueueItem>[
      for (final ep in entryPoints) _QueueItem(doctype: ep, tier: 0),
    ];

    while (frontier.isNotEmpty) {
      // Deduplicate within the level (multiple parents may point at the
      // same child). Preserve the lowest tier seen for each doctype.
      final byDoctype = <String, _QueueItem>{};
      for (final item in frontier) {
        if (outgoingByDt.containsKey(item.doctype)) {
          if (item.tier < (tierMap[item.doctype] ?? item.tier)) {
            tierMap[item.doctype] = item.tier;
          }
          continue;
        }
        final existing = byDoctype[item.doctype];
        if (existing == null || item.tier < existing.tier) {
          byDoctype[item.doctype] = item;
        }
      }

      // Fetch this level's metas through a small worker pool. Each
      // worker grabs the next unvisited doctype in submission order.
      final levelItems = byDoctype.values.toList();
      final levelMetas = <String, DocTypeMeta>{};
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final myIdx = next++;
          if (myIdx >= levelItems.length) return;
          final item = levelItems[myIdx];
          try {
            levelMetas[item.doctype] = await metaFetcher(item.doctype);
          } catch (e) {
            warnings.add('Missing meta for "${item.doctype}": $e');
          }
        }
      }

      final workerCount = metaConcurrency.clamp(1, levelItems.length);
      await Future.wait(
        [for (var i = 0; i < workerCount; i++) worker()],
      );

      // Apply the level's results sequentially — DepGraph maps and
      // child enqueueing don't tolerate concurrent mutation.
      final nextFrontier = <_QueueItem>[];
      for (final item in levelItems) {
        final meta = levelMetas[item.doctype];
        if (meta == null) continue;

        if (meta.isTable) childDoctypes.add(item.doctype);

        final outgoingGraph = DependencyGraphBuilder.buildOutgoing(meta);
        outgoingByDt[item.doctype] = outgoingGraph;
        tierMap[item.doctype] = item.tier;
        incoming.putIfAbsent(item.doctype, () => []);

        for (final e in outgoingGraph.outgoing) {
          if (e.targetDoctype == DependencyGraphBuilder.dynamicLinkSentinel) {
            warnings.add(
              'Skipping Dynamic Link field "${e.field}" on '
              '"${item.doctype}" — target resolved at runtime',
            );
            continue;
          }
          incoming.putIfAbsent(e.targetDoctype, () => []).add(
                DepEdge(
                  field: e.field,
                  targetDoctype: item.doctype,
                  kind: e.kind,
                ),
              );
          if (!outgoingByDt.containsKey(e.targetDoctype)) {
            nextFrontier.add(_QueueItem(
              doctype: e.targetDoctype,
              tier: item.tier + 1,
            ));
          }
        }
      }
      frontier = nextFrontier;
    }

    final finalGraph = <String, DepGraph>{};
    for (final entry in outgoingByDt.entries) {
      finalGraph[entry.key] = DepGraph(
        doctype: entry.key,
        tier: tierMap[entry.key] ?? 0,
        outgoing: entry.value.outgoing
            .where((e) =>
                e.targetDoctype !=
                DependencyGraphBuilder.dynamicLinkSentinel)
            .toList(),
        incoming: incoming[entry.key] ?? const [],
      );
    }

    final doctypes = finalGraph.keys.toList()
      ..sort((a, b) {
        final ta = finalGraph[a]!.tier;
        final tb = finalGraph[b]!.tier;
        final cmp = ta.compareTo(tb);
        return cmp != 0 ? cmp : a.compareTo(b);
      });

    return ClosureResult(
      doctypes: doctypes,
      graph: finalGraph,
      childDoctypes: childDoctypes,
      warnings: warnings,
    );
  }
}

class _QueueItem {
  final String doctype;
  final int tier;
  _QueueItem({required this.doctype, required this.tier});
}
