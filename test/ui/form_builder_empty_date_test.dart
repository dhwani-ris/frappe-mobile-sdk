// A saved record reopened with an empty optional Date showed
// "Form Render Error: type 'String' is not a subtype of type 'DateTime?'".
//
// The save payload filled every untouched field with '' — Date fields
// included — so the local row came back holding ''. DateField parses its own
// value (null for ''), and flutter_form_builder then falls back to the form's
// `initialValue[name]` and casts it: `'' as DateTime?` throws.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  fields: [
    DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title'),
    DocField(fieldname: 'd', fieldtype: 'Date', label: 'D'),
    DocField(fieldname: 'dt', fieldtype: 'Datetime', label: 'DT'),
    DocField(fieldname: 't', fieldtype: 'Time', label: 'T'),
  ],
);

void main() {
  for (final mode in FormBuilderMode.values) {
    for (final stored in <Object?>['', 'not-a-date', '   ']) {
      testWidgets('$mode: a stored ${stored == '' ? 'empty' : '"$stored"'} '
          'date/time value renders instead of throwing', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FrappeFormBuilder(
                meta: _meta(),
                mode: mode,
                initialData: {'title': 'A', 'd': stored, 'dt': stored, 't': stored},
                onSubmit: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('D'), findsWidgets);
      });
    }

    testWidgets('$mode: a stored real date still shows', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: _meta(),
              mode: mode,
              initialData: const {'title': 'A', 'd': '2026-10-06'},
              onSubmit: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('2026-10-06'), findsOneWidget);
    });

    testWidgets('$mode: untouched date/time fields save as null, not ""', (
      tester,
    ) async {
      Map<String, dynamic>? submitted;
      void Function()? submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: _meta(),
              mode: mode,
              initialData: const {'title': 'A'},
              onSubmit: (data) => submitted = data,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pump();
      submit!();
      await tester.pumpAndSettle();
      expect(submitted, isNotNull);
      expect(submitted!['d'], isNull);
      expect(submitted!['dt'], isNull);
      expect(submitted!['t'], isNull);
      expect(submitted!['title'], 'A');
    });
  }
}
