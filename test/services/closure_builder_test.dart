import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/closure_builder.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocField f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, label: n, options: options);

Map<String, DocTypeMeta> catalog() => {
      'Sales Order': DocTypeMeta(name: 'Sales Order', fields: [
        f('customer', 'Link', options: 'Customer'),
        f('items', 'Table', options: 'Sales Order Item'),
      ]),
      'Customer': DocTypeMeta(name: 'Customer', fields: [
        f('territory', 'Link', options: 'Territory'),
      ]),
      'Territory': DocTypeMeta(name: 'Territory', fields: const []),
      'Sales Order Item': DocTypeMeta(
        name: 'Sales Order Item',
        isTable: true,
        fields: [f('item_code', 'Data')],
      ),
    };

void main() {
  group('ClosureBuilder', () {
    test('entry → Link → Link terminal, plus a child doctype', () async {
      final cat = catalog();
      final result = await ClosureBuilder.build(
        entryPoints: const ['Sales Order'],
        metaFetcher: (dt) async => cat[dt]!,
      );

      expect(
        result.doctypes.toSet(),
        {'Sales Order', 'Customer', 'Territory', 'Sales Order Item'},
      );
      expect(result.graph['Sales Order']!.tier, 0);
      expect(result.graph['Customer']!.tier, 1);
      expect(result.graph['Territory']!.tier, 2);
      expect(result.childDoctypes, contains('Sales Order Item'));
    });

    test('incoming edges populated', () async {
      final cat = catalog();
      final result = await ClosureBuilder.build(
        entryPoints: const ['Sales Order'],
        metaFetcher: (dt) async => cat[dt]!,
      );
      final custIncoming = result.graph['Customer']!.incoming;
      expect(custIncoming.length, 1);
      expect(custIncoming.first.targetDoctype, 'Sales Order');
      expect(custIncoming.first.field, 'customer');
    });

    test('skips Dynamic Link targets, records warning', () async {
      final cat = {
        'Comment': DocTypeMeta(name: 'Comment', fields: [
          f('reference_name', 'Dynamic Link', options: 'reference_doctype'),
        ]),
      };
      final result = await ClosureBuilder.build(
        entryPoints: const ['Comment'],
        metaFetcher: (dt) async => cat[dt]!,
      );
      expect(result.doctypes, ['Comment']);
      expect(result.warnings.any((w) => w.contains('Dynamic Link')), isTrue);
    });

    test('cycle — A→B→A — is walked once per doctype', () async {
      final cat = {
        'A': DocTypeMeta(name: 'A', fields: [f('b_ref', 'Link', options: 'B')]),
        'B': DocTypeMeta(name: 'B', fields: [f('a_ref', 'Link', options: 'A')]),
      };
      final result = await ClosureBuilder.build(
        entryPoints: const ['A'],
        metaFetcher: (dt) async => cat[dt]!,
      );
      expect(result.doctypes.toSet(), {'A', 'B'});
      expect(result.graph['A']!.tier, 0);
      expect(result.graph['B']!.tier, 1);
    });

    test('missing target meta → warning, closure continues', () async {
      final cat = {
        'A': DocTypeMeta(name: 'A', fields: [f('miss', 'Link', options: 'Ghost')]),
      };
      final result = await ClosureBuilder.build(
        entryPoints: const ['A'],
        metaFetcher: (dt) async {
          if (cat.containsKey(dt)) return cat[dt]!;
          throw ArgumentError('no meta: $dt');
        },
      );
      expect(result.doctypes, contains('A'));
      expect(result.warnings.any((w) => w.contains('Ghost')), isTrue);
    });

    test('multiple entry points merged', () async {
      final cat = {
        'A': DocTypeMeta(name: 'A', fields: [f('x', 'Link', options: 'X')]),
        'B': DocTypeMeta(name: 'B', fields: [f('y', 'Link', options: 'Y')]),
        'X': DocTypeMeta(name: 'X', fields: const []),
        'Y': DocTypeMeta(name: 'Y', fields: const []),
      };
      final result = await ClosureBuilder.build(
        entryPoints: const ['A', 'B'],
        metaFetcher: (dt) async => cat[dt]!,
      );
      expect(result.doctypes.toSet(), {'A', 'B', 'X', 'Y'});
    });

    test('shared target appears once + meta fetched once', () async {
      // Three entry points all link to Customer. The closure must list
      // Customer exactly once and fetch its meta exactly once — so the
      // initial-sync caller pulls Customer once, not three times.
      final cat = {
        'Order': DocTypeMeta(name: 'Order',
            fields: [f('customer', 'Link', options: 'Customer')]),
        'Quote': DocTypeMeta(name: 'Quote',
            fields: [f('customer', 'Link', options: 'Customer')]),
        'Invoice': DocTypeMeta(name: 'Invoice',
            fields: [f('customer', 'Link', options: 'Customer')]),
        'Customer': DocTypeMeta(name: 'Customer', fields: const []),
      };
      final fetchCount = <String, int>{};
      final result = await ClosureBuilder.build(
        entryPoints: const ['Order', 'Quote', 'Invoice'],
        metaFetcher: (dt) async {
          fetchCount[dt] = (fetchCount[dt] ?? 0) + 1;
          return cat[dt]!;
        },
      );
      expect(result.doctypes.where((d) => d == 'Customer').length, 1,
          reason: 'Customer must appear exactly once in the closure');
      expect(fetchCount['Customer'], 1,
          reason: 'meta for shared target fetched exactly once');
      expect(result.doctypes.toSet(),
          {'Order', 'Quote', 'Invoice', 'Customer'});
    });

    test('is_child_table reflects meta.istable', () async {
      final cat = catalog();
      final result = await ClosureBuilder.build(
        entryPoints: const ['Sales Order'],
        metaFetcher: (dt) async => cat[dt]!,
      );
      expect(result.childDoctypes, {'Sales Order Item'});
    });
  });
}
