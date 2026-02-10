import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  testWidgets(
    'FrappeFormBuilder validates required fields and calls onSubmit',
    (WidgetTester tester) async {
      final meta = DocTypeMeta(
        name: 'TestDoctype',
        fields: <DocField>[
          DocField(
            fieldname: 'name',
            fieldtype: 'Data',
            label: 'Name',
            reqd: true,
          ),
        ],
      );

      Map<String, dynamic>? submitted;
      void Function()? submitFn;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: meta,
              onSubmit: (Map<String, dynamic> data) => submitted = data,
              registerSubmit: (void Function() fn) => submitFn = fn,
            ),
          ),
        ),
      );

      // No value entered yet; submit should fail validation.
      expect(submitted, isNull);
      expect(submitFn, isNotNull);

      submitFn!.call();
      await tester.pumpAndSettle();
      expect(submitted, isNull);

      // Enter a value and submit again.
      await tester.enterText(find.byType(TextFormField).first, 'John');
      submitFn!.call();
      await tester.pumpAndSettle();

      expect(submitted, isNotNull);
      expect(submitted!['name'], 'John');
    },
  );
}
