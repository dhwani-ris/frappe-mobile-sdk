import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/index_policy.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';

DocTypeMeta metaWith({
  String doctype = 'SEDVR',
  String? titleField,
  String? sortField,
  List<String>? searchFields,
  List<DocField> fields = const [],
}) {
  return DocTypeMeta(
    name: doctype,
    titleField: titleField,
    sortField: sortField,
    searchFields: searchFields,
    fields: fields,
  );
}

DocField field(String name, String type) =>
    DocField(fieldname: name, fieldtype: type, label: name);

void main() {
  group('chooseIndexes', () {
    test('always includes server_name + modified + sync_status', () {
      final meta = metaWith();
      final cols = chooseIndexes(meta, maxIndexes: 7);
      expect(cols, containsAll(['server_name', 'modified', 'sync_status']));
    });

    test('respects max cap', () {
      final meta = metaWith(
        titleField: 'name',
        sortField: 'modified',
        searchFields: ['a', 'b', 'c', 'd'],
        fields: [
          field('a', 'Data'),
          field('b', 'Data'),
          field('c', 'Data'),
          field('d', 'Data'),
          field('ln1', 'Link'),
          field('ln2', 'Link'),
          field('ln3', 'Link'),
          field('ln4', 'Link'),
        ],
      );
      final cols = chooseIndexes(meta, maxIndexes: 7);
      expect(cols.length, 7);
    });

    test('prefers title_field__norm when it is a text field', () {
      final meta = metaWith(
        titleField: 'full_name',
        fields: [field('full_name', 'Data')],
      );
      final cols = chooseIndexes(meta, maxIndexes: 7);
      expect(cols, contains('full_name__norm'));
    });

    test('search_fields beat Link fields for remaining slots', () {
      final meta = metaWith(
        searchFields: ['a_search', 'b_search'],
        fields: [
          field('a_search', 'Data'),
          field('b_search', 'Data'),
          field('ln1', 'Link'),
          field('ln2', 'Link'),
          field('ln3', 'Link'),
          field('ln4', 'Link'),
        ],
      );
      final cols = chooseIndexes(meta, maxIndexes: 7);
      expect(cols, containsAll(['a_search__norm', 'b_search__norm']));
    });

    test('Link fields ordered by linkEdgeCount when provided', () {
      final meta = metaWith(
        fields: [
          field('lnA', 'Link'),
          field('lnB', 'Link'),
          field('lnC', 'Link'),
        ],
      );
      final cols = chooseIndexes(
        meta,
        maxIndexes: 5,
        linkEdgeCount: {'lnB': 10, 'lnA': 5, 'lnC': 1},
      );
      expect(cols, ['server_name', 'modified', 'sync_status', 'lnB', 'lnA']);
    });

    test('layout fieldtypes are never indexed', () {
      final meta = metaWith(
        fields: [
          field('break1', 'Section Break'),
          field('useful', 'Link'),
        ],
      );
      final cols = chooseIndexes(meta, maxIndexes: 5);
      expect(cols, isNot(contains('break1')));
      expect(cols, contains('useful'));
    });
  });
}
