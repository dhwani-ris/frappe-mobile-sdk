import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/link_filter_result.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';

void main() {
  group('resolveFilters', () {
    final field = DocField(
      fieldname: 'learner',
      fieldtype: 'Link',
      options: 'Learner',
      linkFilters: jsonEncode([
        ['Learner', 'village', '=', 'eval: doc.village'],
      ]),
    );

    test('hook returns filters → those filters are used', () {
      final out = LinkOptionService.resolveFilters(
        field: field,
        rowData: const {},
        parentFormData: const {'village': 'V1'},
        hook: (f, name, row, parent) => const LinkFilterResult(
          filters: [
            ['Learner', 'hamlet', '=', 'H1'],
          ],
        ),
      );
      expect(out, [
        ['Learner', 'hamlet', '=', 'H1'],
      ]);
    });

    test(
      'hook returns LinkFilterResult(filters: null) → null, no meta fallback',
      () {
        final out = LinkOptionService.resolveFilters(
          field: field,
          rowData: const {},
          parentFormData: const {'village': 'V1'},
          hook: (f, name, row, parent) => const LinkFilterResult(filters: null),
        );
        expect(out, isNull);
      },
    );

    test('hook returns LinkFilterResult(filters: []) → normalized to null', () {
      final out = LinkOptionService.resolveFilters(
        field: field,
        rowData: const {},
        parentFormData: const {'village': 'V1'},
        hook: (f, name, row, parent) => const LinkFilterResult(filters: []),
      );
      expect(out, isNull);
    });

    test('hook returns null → meta fallback applies (rowData-only)', () {
      final out = LinkOptionService.resolveFilters(
        field: field,
        rowData: const {'village': 'V1'},
        parentFormData: const {},
        hook: (f, name, row, parent) => null,
      );
      expect(out, [
        ['Learner', 'village', '=', 'V1'],
      ]);
    });

    test('no hook → meta fallback applies (rowData-only)', () {
      final out = LinkOptionService.resolveFilters(
        field: field,
        rowData: const {'village': 'V1'},
        parentFormData: const {},
        hook: null,
      );
      expect(out, [
        ['Learner', 'village', '=', 'V1'],
      ]);
    });

    test('no hook, no meta → null', () {
      final plainField = DocField(
        fieldname: 'x',
        fieldtype: 'Link',
        options: 'Foo',
      );
      final out = LinkOptionService.resolveFilters(
        field: plainField,
        rowData: const {},
        parentFormData: const {},
        hook: null,
      );
      expect(out, isNull);
    });

    test('hook skipped when field.fieldname is null → meta fallback', () {
      final unnamed = DocField(
        fieldname: null,
        fieldtype: 'Link',
        options: 'Learner',
        linkFilters: jsonEncode([
          ['Learner', 'village', '=', 'eval: doc.village'],
        ]),
      );
      var hookCalled = false;
      final out = LinkOptionService.resolveFilters(
        field: unnamed,
        rowData: const {'village': 'V1'},
        parentFormData: const {},
        hook: (f, name, row, parent) {
          hookCalled = true;
          return const LinkFilterResult(
            filters: [
              ['x', 'y', '=', 'z'],
            ],
          );
        },
      );
      expect(hookCalled, isFalse);
      expect(out, [
        ['Learner', 'village', '=', 'V1'],
      ]);
    });
  });

  group('_normalizeFiltersForDoctype (C1)', () {
    test('3-tuple [field, op, value] is promoted to 4-tuple with doctype', () {
      final result = LinkOptionService.normalizeFiltersForDoctypeForTesting(
        'Village',
        [
          ['state', '=', 'Active'],
        ],
      );
      expect(result, [
        ['Village', 'state', '=', 'Active'],
      ]);
    });

    test('4-tuple with matching doctype is kept as-is', () {
      final result = LinkOptionService.normalizeFiltersForDoctypeForTesting(
        'Village',
        [
          ['Village', 'state', '=', 'Active'],
        ],
      );
      expect(result, [
        ['Village', 'state', '=', 'Active'],
      ]);
    });

    test(
      '4-tuple with mismatched doctype is normalised to queried doctype',
      () {
        final result = LinkOptionService.normalizeFiltersForDoctypeForTesting(
          'Village',
          [
            ['Villages', 'state', '=', 'Active'],
          ],
        );
        expect(result, [
          ['Village', 'state', '=', 'Active'],
        ]);
      },
    );

    test('malformed filter (length < 3) returns null (skipped)', () {
      final result = LinkOptionService.normalizeFiltersForDoctypeForTesting(
        'Village',
        [
          ['junk'],
        ],
      );
      expect(result, isNull);
    });
  });

  group('TableMultiSelect-shape regression', () {
    test(
      'resolveFilters applies meta linkFilters for Table MultiSelect (rowData-only)',
      () {
        final field = DocField(
          fieldname: 'tags',
          fieldtype: 'Table MultiSelect',
          options: 'Tag',
          linkFilters: jsonEncode([
            ['Tag', 'category', '=', 'eval: doc.category'],
          ]),
        );
        final out = LinkOptionService.resolveFilters(
          field: field,
          rowData: const {'category': 'C1'},
          parentFormData: const {},
          hook: null,
        );
        expect(out, [
          ['Tag', 'category', '=', 'C1'],
        ]);
      },
    );
  });
}
