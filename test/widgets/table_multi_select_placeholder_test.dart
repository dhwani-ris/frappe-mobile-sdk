// Regression: the Table MultiSelect field must forward its configured
// `placeholder` to the underlying SearchableSelect search input, like every
// other field type (Data/Link/etc.). Before the fix it passed no hintText, so
// the configured placeholder was silently dropped in favour of the generic
// "Search & select..." default.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/entities/link_option_entity.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/table_multi_select_field.dart';

class _StubLinkOptionService extends LinkOptionService {
  _StubLinkOptionService() : super.withoutResolver();
  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async => const [];
}

DocTypeMeta _childMeta() => DocTypeMeta(
  name: 'Fee Component Table',
  isTable: true,
  fields: <DocField>[
    DocField(
      fieldname: 'component',
      fieldtype: 'Link',
      options: 'Fee Component',
    ),
  ],
);

Widget _wrap(DocField field) => MaterialApp(
  home: Scaffold(
    body: TableMultiSelectFieldBase(
      field: field,
      rows: const <dynamic>[],
      onChanged: null,
      enabled: true,
      getMeta: (_) async => _childMeta(),
      linkOptionService: _StubLinkOptionService(),
    ),
  ),
);

void main() {
  testWidgets('forwards the configured placeholder as the search hint', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DocField(
          fieldname: 'components',
          fieldtype: 'Table MultiSelect',
          options: 'Fee Component Table',
          label: 'Components',
          placeholder: 'Pick components',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Pick components'),
      findsOneWidget,
      reason: 'configured placeholder must reach the SearchableSelect hint',
    );
  });

  testWidgets('falls back to the generic hint when no placeholder is set', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DocField(
          fieldname: 'components',
          fieldtype: 'Table MultiSelect',
          options: 'Fee Component Table',
          label: 'Components',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Search & select...'), findsOneWidget);
  });
}
