import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/dependency_graph_builder.dart';
import 'package:frappe_mobile_sdk/src/models/dep_graph.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocField f(String name, String type, {String? options}) =>
    DocField(fieldname: name, fieldtype: type, label: name, options: options);

void main() {
  group('DependencyGraphBuilder.buildOutgoing', () {
    test('no fields → no edges', () {
      final meta = DocTypeMeta(name: 'Leaf', fields: const []);
      final g = DependencyGraphBuilder.buildOutgoing(meta);
      expect(g.outgoing, isEmpty);
      expect(g.doctype, 'Leaf');
    });

    test('Link field emits a link edge', () {
      final meta = DocTypeMeta(
        name: 'SO',
        fields: [f('customer', 'Link', options: 'Customer')],
      );
      final g = DependencyGraphBuilder.buildOutgoing(meta);
      expect(g.outgoing.length, 1);
      expect(g.outgoing.first.field, 'customer');
      expect(g.outgoing.first.targetDoctype, 'Customer');
      expect(g.outgoing.first.kind, DepEdgeKind.link);
    });

    test('Table field emits a child edge', () {
      final meta = DocTypeMeta(
        name: 'SO',
        fields: [f('items', 'Table', options: 'Sales Order Item')],
      );
      final g = DependencyGraphBuilder.buildOutgoing(meta);
      expect(g.outgoing.first.kind, DepEdgeKind.child);
      expect(g.outgoing.first.targetDoctype, 'Sales Order Item');
    });

    test('Table MultiSelect emits a child edge', () {
      final meta = DocTypeMeta(
        name: 'SO',
        fields: [f('taxes', 'Table MultiSelect', options: 'Tax')],
      );
      final g = DependencyGraphBuilder.buildOutgoing(meta);
      expect(g.outgoing.first.kind, DepEdgeKind.child);
    });

    test('Dynamic Link emits an edge with sentinel target', () {
      final meta = DocTypeMeta(
        name: 'Comment',
        fields: [
          f('reference_name',
              'Dynamic Link',
              options: 'reference_doctype'),
        ],
      );
      final g = DependencyGraphBuilder.buildOutgoing(meta);
      expect(g.outgoing.first.targetDoctype, '*Dynamic*');
      expect(g.outgoing.first.kind, DepEdgeKind.link);
    });

    test('Link with no options is skipped (malformed meta)', () {
      final meta = DocTypeMeta(
        name: 'X',
        fields: [f('broken', 'Link')],
      );
      final g = DependencyGraphBuilder.buildOutgoing(meta);
      expect(g.outgoing, isEmpty);
    });

    test('layout + button fields do not emit edges', () {
      final meta = DocTypeMeta(
        name: 'X',
        fields: [
          f('break1', 'Section Break'),
          f('click_me', 'Button'),
          f('real_link', 'Link', options: 'Customer'),
        ],
      );
      final g = DependencyGraphBuilder.buildOutgoing(meta);
      expect(g.outgoing.length, 1);
      expect(g.outgoing.first.field, 'real_link');
    });
  });
}
