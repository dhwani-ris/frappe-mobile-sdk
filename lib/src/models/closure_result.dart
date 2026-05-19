import 'dep_graph.dart';

class ClosureResult {
  /// All doctype names in the closure, ordered by tier asc then alphabetic.
  final List<String> doctypes;

  /// Per-doctype graph (tier + outgoing + incoming). Keyed by doctype name.
  final Map<String, DepGraph> graph;

  /// Subset that are child doctypes (istable=1). Flagged separately because
  /// they're never pulled independently by PullEngine (they ride with parents).
  final Set<String> childDoctypes;

  /// Non-fatal notes — e.g. Dynamic Link skipped, missing target meta.
  final List<String> warnings;

  const ClosureResult({
    required this.doctypes,
    required this.graph,
    required this.childDoctypes,
    required this.warnings,
  });
}
