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

    test('hook throws → falls back to meta linkFilters (no rethrow)', () {
      final out = LinkOptionService.resolveFilters(
        field: field,
        rowData: const {'village': 'V1'},
        parentFormData: const {},
        hook: (f, name, row, parent) => throw StateError('host hook blew up'),
      );
      expect(out, [
        ['Learner', 'village', '=', 'V1'],
      ]);
    });

    test('hook throws with no meta linkFilters → null (does not rethrow)', () {
      final plainField = DocField(
        fieldname: 'learner',
        fieldtype: 'Link',
        options: 'Learner',
      );
      final out = LinkOptionService.resolveFilters(
        field: plainField,
        rowData: const {},
        parentFormData: const {},
        hook: (f, name, row, parent) => throw TypeError(),
      );
      expect(out, isNull);
    });

    test('hook throws on null deref (realistic host bug) → meta fallback', () {
      // Mirrors a common host mistake: bang-deref of a missing parent key.
      final out = LinkOptionService.resolveFilters(
        field: field,
        rowData: const {'village': 'V1'},
        parentFormData: const {},
        hook: (f, name, row, parent) {
          final missing = parent['nope']! as String; // throws at runtime
          return LinkFilterResult(
            filters: [
              ['Learner', 'x', '=', missing],
            ],
          );
        },
      );
      expect(out, [
        ['Learner', 'village', '=', 'V1'],
      ]);
    });

    test(
      'meta linkFilters referencing parent field resolves from parentFormData',
      () {
        final out = LinkOptionService.resolveFilters(
          field: field,
          rowData: const {},
          parentFormData: const {'village': 'V1'},
          hook: null,
        );
        expect(out, [
          ['Learner', 'village', '=', 'V1'],
        ]);
      },
    );

    test('rowData wins over parentFormData on key collision', () {
      final out = LinkOptionService.resolveFilters(
        field: field,
        rowData: const {'village': 'CHILD'},
        parentFormData: const {'village': 'PARENT'},
        hook: null,
      );
      expect(out, [
        ['Learner', 'village', '=', 'CHILD'],
      ]);
    });

    test(
      'mixed meta filters: row-only field resolves from rowData, parent-only '
      'from parentFormData',
      () {
        final mixedField = DocField(
          fieldname: 'block',
          fieldtype: 'Link',
          options: 'Block',
          linkFilters: jsonEncode([
            ['Block', 'state', '=', 'eval: doc.state'],
            ['Block', 'district', '=', 'eval: doc.district'],
          ]),
        );
        final out = LinkOptionService.resolveFilters(
          field: mixedField,
          rowData: const {'state': 'S1'},
          parentFormData: const {'district': 'D1'},
          hook: null,
        );
        expect(out, [
          ['Block', 'state', '=', 'S1'],
          ['Block', 'district', '=', 'D1'],
        ]);
      },
    );
  });

  group('safeHook', () {
    test('null factory → null builder', () {
      final builder = LinkOptionService.safeHook(null, 'Learner', 'learner');
      expect(builder, isNull);
    });

    test('factory returns null → null builder', () {
      final builder = LinkOptionService.safeHook(
        (doctype, fieldname) => null,
        'Learner',
        'learner',
      );
      expect(builder, isNull);
    });

    test('factory returns a builder → that builder is returned', () {
      LinkFilterResult? hook(
        DocField f,
        String name,
        Map<String, dynamic> row,
        Map<String, dynamic> parent,
      ) => const LinkFilterResult(
        filters: [
          ['Learner', 'state', '=', 'Active'],
        ],
      );
      final builder = LinkOptionService.safeHook(
        (doctype, fieldname) => hook,
        'Learner',
        'learner',
      );
      expect(builder, same(hook));
    });

    test('factory throws → null builder (does not rethrow)', () {
      final builder = LinkOptionService.safeHook(
        (doctype, fieldname) => throw StateError('factory blew up'),
        'Learner',
        'learner',
      );
      expect(builder, isNull);
    });

    test('end-to-end: throwing factory → meta fallback via resolveFilters', () {
      // The 5 SDK call sites route the factory through safeHook so a thrown
      // factory must degrade to meta linkFilters, not abort the field.
      final out = LinkOptionService.resolveFilters(
        field: DocField(
          fieldname: 'learner',
          fieldtype: 'Link',
          options: 'Learner',
          linkFilters: jsonEncode([
            ['Learner', 'village', '=', 'eval: doc.village'],
          ]),
        ),
        rowData: const {'village': 'V1'},
        parentFormData: const {},
        hook: LinkOptionService.safeHook(
          (doctype, fieldname) => throw StateError('factory blew up'),
          'Learner',
          'learner',
        ),
      );
      expect(out, [
        ['Learner', 'village', '=', 'V1'],
      ]);
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
