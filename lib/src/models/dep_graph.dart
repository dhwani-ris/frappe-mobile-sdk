enum DepEdgeKind { link, child }

class DepEdge {
  final String field;
  final String targetDoctype;
  final DepEdgeKind kind;

  const DepEdge({
    required this.field,
    required this.targetDoctype,
    required this.kind,
  });

  Map<String, Object?> toJson() => {
        'field': field,
        'target': targetDoctype,
        'kind': kind.name,
      };

  factory DepEdge.fromJson(Map<String, dynamic> j) => DepEdge(
        field: j['field'] as String,
        targetDoctype: j['target'] as String,
        kind: DepEdgeKind.values.firstWhere((k) => k.name == j['kind']),
      );
}

class DepGraph {
  final String doctype;
  final int tier;
  final List<DepEdge> outgoing;
  final List<DepEdge> incoming;

  const DepGraph({
    required this.doctype,
    required this.tier,
    required this.outgoing,
    required this.incoming,
  });

  Map<String, Object?> toJson() => {
        'doctype': doctype,
        'tier': tier,
        'outgoing': outgoing.map((e) => e.toJson()).toList(),
        'incoming': incoming.map((e) => e.toJson()).toList(),
      };

  factory DepGraph.fromJson(Map<String, dynamic> j) => DepGraph(
        doctype: j['doctype'] as String,
        tier: (j['tier'] as num).toInt(),
        outgoing: ((j['outgoing'] as List?) ?? const [])
            .map((e) => DepEdge.fromJson(e as Map<String, dynamic>))
            .toList(),
        incoming: ((j['incoming'] as List?) ?? const [])
            .map((e) => DepEdge.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// Counts per outgoing Link field (child edges excluded). Used by
  /// chooseIndexes() to rank Link columns for index slots.
  ///
  /// **TODO (P3):** the spec §4.6 calls for "Link fields ordered by dep-graph
  /// edge count (most-queried first)". A single doctype's outgoing list has
  /// each field exactly once, so this currently returns 1 for every Link
  /// field — effectively making the index ranking insertion-order. The
  /// correct ranking signal is the *target doctype's* incoming-edge count
  /// (a Link to a popular target ranks higher), which requires the full
  /// closure as input. PullEngine in P3 has that context; until then,
  /// chooseIndexes() falls back to insertion order, which is acceptable
  /// because the 7-index cap is rarely binding for typical doctypes.
  Map<String, int> linkEdgeCountByField() {
    final out = <String, int>{};
    for (final e in outgoing) {
      if (e.kind == DepEdgeKind.link) {
        out[e.field] = (out[e.field] ?? 0) + 1;
      }
    }
    return out;
  }
}
