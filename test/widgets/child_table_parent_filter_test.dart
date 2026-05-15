import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

void main() {
  testWidgets(
    'FrappeFormBuilder accepts parentFormData and getLinkFilterBuilder',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'X',
                fields: [DocField(fieldname: 'a', fieldtype: 'Data')],
              ),
              initialData: const {},
              parentFormData: const {'hamlet': 'H1'},
              getLinkFilterBuilder: (doctype, fieldname) => null,
            ),
          ),
        ),
      );
      await tester.pump();
      // If it compiled and pumped without error, the params are plumbed.
      expect(find.byType(FrappeFormBuilder), findsOneWidget);
    },
  );
}
