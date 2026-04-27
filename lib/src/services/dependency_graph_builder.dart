import '../models/dep_graph.dart';
import '../models/doc_type_meta.dart';
import '../database/field_type_mapping.dart';

/// Computes the outgoing edges of a single doctype from its DocTypeMeta.
/// Tier and incoming edges are filled in later by ClosureBuilder.
class DependencyGraphBuilder {
  static const dynamicLinkSentinel = '*Dynamic*';

  static DepGraph buildOutgoing(DocTypeMeta meta) {
    final edges = <DepEdge>[];
    for (final f in meta.fields) {
      final name = f.fieldname;
      final type = f.fieldtype;
      if (name == null) continue;

      if (type == 'Link') {
        final opt = (f.options ?? '').trim();
        if (opt.isEmpty) continue;
        edges.add(DepEdge(
          field: name,
          targetDoctype: opt,
          kind: DepEdgeKind.link,
        ));
      } else if (type == 'Dynamic Link') {
        edges.add(DepEdge(
          field: name,
          targetDoctype: dynamicLinkSentinel,
          kind: DepEdgeKind.link,
        ));
      } else if (isChildTableFieldType(type)) {
        final opt = (f.options ?? '').trim();
        if (opt.isEmpty) continue;
        edges.add(DepEdge(
          field: name,
          targetDoctype: opt,
          kind: DepEdgeKind.child,
        ));
      }
    }
    return DepGraph(
      doctype: meta.name,
      tier: -1,
      outgoing: edges,
      incoming: const [],
    );
  }
}
