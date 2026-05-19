import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/entities/link_option_entity.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/link_filter_result.dart';
import 'package:frappe_mobile_sdk/src/services/link_option_service.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/table_multi_select_field.dart';

class _RecordingLinkOptionService extends LinkOptionService {
  _RecordingLinkOptionService() : super.withoutResolver();

  final List<String> queriedDoctypes = [];

  @override
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    queriedDoctypes.add(doctype);
    return const [];
  }
}

void main() {
  // Outer TMS field on the parent form: fieldname "components", points at
  // child table "Fee Component Table" which contains ONE inner Link field
  // ("component") targeting the real link-target doctype ("Fee Component").
  final outerField = DocField(
    fieldname: 'components',
    fieldtype: 'Table MultiSelect',
    options: 'Fee Component Table',
  );
  final childMeta = DocTypeMeta(
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
  Future<DocTypeMeta> getMeta(String name) async => childMeta;

  testWidgets(
    'TMS hook lookup uses the INNER Link\'s (options, fieldname)',
    (tester) async {
      final recordedKeys = <(String, String)>[];
      DocField? hookReceivedField;
      final service = _RecordingLinkOptionService();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TableMultiSelectFieldBase(
              field: outerField,
              rows: const <dynamic>[],
              onChanged: null,
              enabled: true,
              getMeta: getMeta,
              linkOptionService: service,
              formData: const <String, dynamic>{},
              parentFormData: const <String, dynamic>{'category': 'C1'},
              getLinkFilterBuilder: (doctype, fieldname) {
                recordedKeys.add((doctype, fieldname));
                if (doctype == 'Fee Component' && fieldname == 'component') {
                  return (field, name, row, parent) {
                    hookReceivedField = field;
                    return LinkFilterResult(filters: [
                      ['Fee Component', 'category', '=', parent['category']],
                    ]);
                  };
                }
                return null;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Registry lookup must use the INNER Link's doctype + fieldname.
      expect(
        recordedKeys,
        contains(('Fee Component', 'component')),
        reason: 'Hook registry lookup must key by the inner Link\'s '
            '(options, fieldname) to match the plain Link convention',
      );
      // And must NOT use the outer TMS's doctype + fieldname.
      expect(
        recordedKeys,
        isNot(contains(('Fee Component Table', 'components'))),
        reason: 'Hook registry lookup must not key by the outer TMS field',
      );

      // The hook body must receive the INNER Link DocField so apps can
      // inspect .options / .fieldname reliably.
      expect(hookReceivedField, isNotNull,
          reason: 'Hook registered at the correct key must fire');
      expect(hookReceivedField!.fieldname, 'component');
      expect(hookReceivedField!.options, 'Fee Component');

      // And the service was queried against the inner Link\'s target doctype.
      expect(service.queriedDoctypes, contains('Fee Component'));
    },
  );
}
