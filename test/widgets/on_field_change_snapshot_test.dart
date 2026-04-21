import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

void main() {
  testWidgets(
    'onFieldChange receives a snapshot of formData, not a live reference',
    (tester) async {
      final meta = DocTypeMeta(
        name: 'TestDoctype',
        fields: <DocField>[
          DocField(fieldname: 'a', fieldtype: 'Data', label: 'A'),
          DocField(fieldname: 'b', fieldtype: 'Data', label: 'B'),
        ],
      );

      Map<String, dynamic>? lastEmitted;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta,
              onFieldChange: (fieldName, newValue, formData) {
                // Attempt to leak state into the SDK's internal map.
                formData['sneaky'] = 'leaked';
                return null;
              },
              onFormDataChanged: (data) => lastEmitted = data,
            ),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('data_a')),
        'hello',
      );
      await tester.pumpAndSettle();

      expect(lastEmitted, isNotNull,
          reason: 'onFormDataChanged must fire after a field edit');
      expect(
        lastEmitted!.containsKey('sneaky'),
        isFalse,
        reason: 'onFieldChange must receive a snapshot; mutations must not '
            'propagate into the SDK\'s _formData',
      );
    },
  );
}
