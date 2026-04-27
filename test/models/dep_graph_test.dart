import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/dep_graph.dart';

void main() {
  group('DepGraph', () {
    test('round-trip to/from JSON', () {
      final g = DepGraph(
        doctype: 'Sales Order',
        tier: 1,
        outgoing: [
          DepEdge(
            field: 'customer',
            targetDoctype: 'Customer',
            kind: DepEdgeKind.link,
          ),
          DepEdge(
            field: 'items',
            targetDoctype: 'Sales Order Item',
            kind: DepEdgeKind.child,
          ),
        ],
        incoming: [
          DepEdge(
            field: 'source_order',
            targetDoctype: 'Delivery Note',
            kind: DepEdgeKind.link,
          ),
        ],
      );
      final json = jsonEncode(g.toJson());
      final back = DepGraph.fromJson(jsonDecode(json) as Map<String, dynamic>);
      expect(back.doctype, 'Sales Order');
      expect(back.tier, 1);
      expect(back.outgoing.length, 2);
      expect(back.outgoing.first.kind, DepEdgeKind.link);
      expect(back.outgoing[1].kind, DepEdgeKind.child);
      expect(back.incoming.first.targetDoctype, 'Delivery Note');
    });

    test('empty graph', () {
      final g = DepGraph(
        doctype: 'Leaf',
        tier: 0,
        outgoing: const [],
        incoming: const [],
      );
      final json = jsonEncode(g.toJson());
      final back = DepGraph.fromJson(jsonDecode(json) as Map<String, dynamic>);
      expect(back.outgoing, isEmpty);
      expect(back.incoming, isEmpty);
    });

    test('linkTargetCountByField for index policy', () {
      final g = DepGraph(
        doctype: 'SO',
        tier: 0,
        outgoing: [
          DepEdge(
            field: 'a',
            targetDoctype: 'X',
            kind: DepEdgeKind.link,
          ),
          DepEdge(
            field: 'b',
            targetDoctype: 'Y',
            kind: DepEdgeKind.link,
          ),
          DepEdge(
            field: 'items',
            targetDoctype: 'Z',
            kind: DepEdgeKind.child,
          ),
        ],
        incoming: [
          DepEdge(
            field: 'other',
            targetDoctype: 'Q',
            kind: DepEdgeKind.link,
          ),
        ],
      );
      final counts = g.linkEdgeCountByField();
      expect(counts['a'], 1);
      expect(counts['b'], 1);
      expect(counts.containsKey('items'), isFalse);
    });
  });
}
