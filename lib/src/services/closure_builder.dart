import '../models/closure_result.dart';
import '../models/dep_graph.dart';
import '../models/doc_type_meta.dart';
import 'dependency_graph_builder.dart';

typedef MetaFetcher = Future<DocTypeMeta> Function(String doctype);

class ClosureBuilder {
  /// BFS across Link + Table + Table MultiSelect edges from entry points.
  /// Skips Dynamic Link targets (resolved at runtime). Cycles safe (visited set).
  static Future<ClosureResult> build({
    required List<String> entryPoints,
    required MetaFetcher metaFetcher,
  }) async {
    final outgoingByDt = <String, DepGraph>{};
    final tierMap = <String, int>{};
    final incoming = <String, List<DepEdge>>{};
    final childDoctypes = <String>{};
    final warnings = <String>[];

    final queue = <_QueueItem>[];
    for (final ep in entryPoints) {
      queue.add(_QueueItem(doctype: ep, tier: 0));
    }

    while (queue.isNotEmpty) {
      final item = queue.removeAt(0);
      if (outgoingByDt.containsKey(item.doctype)) {
        // Already visited; keep the lower tier.
        if (item.tier < tierMap[item.doctype]!) {
          tierMap[item.doctype] = item.tier;
        }
        continue;
      }

      DocTypeMeta meta;
      try {
        meta = await metaFetcher(item.doctype);
      } catch (e) {
        warnings.add('Missing meta for "${item.doctype}": $e');
        continue;
      }

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
          queue.add(_QueueItem(
            doctype: e.targetDoctype,
            tier: item.tier + 1,
          ));
        }
      }
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
