// Unit tests for the pure merge/guard helpers extracted from
// OfflineRepository.attachChildRows: `mergeChildRowsIntoData` and
// `metaHasChildTableFields`. Both are plain functions over in-memory
// maps/DocTypeMeta fixtures — no database, no I/O — so the merge shape can
// be pinned independently of the SQLite fetch in `attachChildRows` (covered
// end-to-end by `offline_repository_lookups_test.dart`).
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';

DocField _f(String n, String t, {String? options}) =>
    DocField(fieldname: n, fieldtype: t, options: options);

DocTypeMeta _orderMeta() => DocTypeMeta(
  name: 'Order',
  isTable: false,
  fields: [
    _f('title', 'Data'),
    _f('items', 'Table', options: 'Order Item'),
    _f('tags', 'Table MultiSelect', options: 'Order Tag'),
  ],
);

void main() {
  group('metaHasChildTableFields', () {
    test('true when meta has a Table field', () {
      final meta = DocTypeMeta(
        name: 'Order',
        fields: [
          _f('title', 'Data'),
          _f('items', 'Table', options: 'Order Item'),
        ],
      );
      expect(metaHasChildTableFields(meta), isTrue);
    });

    test('true when meta has a Table MultiSelect field', () {
      final meta = DocTypeMeta(
        name: 'Order',
        fields: [_f('tags', 'Table MultiSelect', options: 'Order Tag')],
      );
      expect(metaHasChildTableFields(meta), isTrue);
    });

    test('false when meta has no child-table fields', () {
      final meta = DocTypeMeta(
        name: 'Customer',
        fields: [_f('customer_name', 'Data'), _f('age', 'Int')],
      );
      expect(metaHasChildTableFields(meta), isFalse);
    });

    test('false for a doctype with no fields at all', () {
      final meta = DocTypeMeta(name: 'Empty', fields: const []);
      expect(metaHasChildTableFields(meta), isFalse);
    });
  });

  group('mergeChildRowsIntoData', () {
    test('populates a Table field from matching child rows', () {
      final merged = mergeChildRowsIntoData(
        {'title': 'O-1'},
        _orderMeta(),
        {
          'items': [
            {'server_name': 'ITEM-1', 'qty': 2},
            {'server_name': 'ITEM-2', 'qty': 5},
          ],
        },
      );
      expect(merged['title'], 'O-1');
      final items = merged['items'] as List;
      expect(items, hasLength(2));
      expect(items[0], {'server_name': 'ITEM-1', 'qty': 2, 'name': 'ITEM-1'});
      expect(items[1], {'server_name': 'ITEM-2', 'qty': 5, 'name': 'ITEM-2'});
    });

    test('populates a Table MultiSelect field the same way as Table', () {
      final merged = mergeChildRowsIntoData(
        {'title': 'O-1'},
        _orderMeta(),
        {
          'tags': [
            {'server_name': 'TAG-1'},
          ],
        },
      );
      final tags = merged['tags'] as List;
      expect(tags, hasLength(1));
      expect(tags.single, {'server_name': 'TAG-1', 'name': 'TAG-1'});
    });

    test('does not overwrite an existing `name` key on a child row', () {
      final merged = mergeChildRowsIntoData({}, _orderMeta(), {
        'items': [
          {'server_name': 'ITEM-1', 'name': 'already-set'},
        ],
      });
      final items = merged['items'] as List;
      expect(items.single['name'], 'already-set');
    });

    test(
      'leaves a Table field untouched when absent from childRowsByField',
      () {
        final merged = mergeChildRowsIntoData(
          {'title': 'O-1'},
          _orderMeta(),
          const {}, // no rows supplied for 'items' or 'tags'
        );
        expect(merged.containsKey('items'), isFalse);
        expect(merged.containsKey('tags'), isFalse);
        expect(merged['title'], 'O-1');
      },
    );

    test('ignores childRowsByField entries for non-Table fields', () {
      final merged = mergeChildRowsIntoData(
        {'title': 'O-1'},
        _orderMeta(),
        {
          // 'title' is a Data field, not Table/Table MultiSelect — must be
          // ignored even though a (bogus) entry is supplied for it.
          'title': [
            {'server_name': 'nope'},
          ],
        },
      );
      expect(merged['title'], 'O-1');
    });

    test('does not mutate the input parentData map', () {
      final input = {'title': 'O-1'};
      final merged = mergeChildRowsIntoData(input, _orderMeta(), {
        'items': [
          {'server_name': 'ITEM-1'},
        ],
      });
      expect(input.containsKey('items'), isFalse);
      expect(merged.containsKey('items'), isTrue);
    });

    test('handles multiple Table fields independently', () {
      final merged = mergeChildRowsIntoData({}, _orderMeta(), {
        'items': [
          {'server_name': 'ITEM-1'},
        ],
        'tags': [
          {'server_name': 'TAG-1'},
          {'server_name': 'TAG-2'},
        ],
      });
      expect((merged['items'] as List), hasLength(1));
      expect((merged['tags'] as List), hasLength(2));
    });

    test('returns parentData fields unchanged when meta has no fields', () {
      final merged = mergeChildRowsIntoData(
        {'a': 1},
        DocTypeMeta(name: 'Empty', fields: const []),
        const {},
      );
      expect(merged, {'a': 1});
    });
  });
}
