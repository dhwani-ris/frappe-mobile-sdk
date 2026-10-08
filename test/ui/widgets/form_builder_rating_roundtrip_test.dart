import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

// A Rating is stored as a 0..1 fraction (Frappe v14+): 3 of 5 stars is 0.6.
// RatingField reads and writes that scale, but the form pipeline re-normalizes
// every value before patching it back into the field. These tests pin that the
// pipeline keeps a saved fraction intact: the stars stay filled after the form
// settles, a single tap selects, and submit returns the same value.

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Survey',
  fields: [DocField(fieldname: 'score', fieldtype: 'Rating', label: 'Score')],
);

Future<void Function()> _pumpForm(
  WidgetTester tester, {
  required FormBuilderMode mode,
  required Map<String, dynamic> initialData,
  required void Function(Map<String, dynamic>) onSubmit,
  Map<String, dynamic>? changed,
}) async {
  void Function()? submitFn;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FrappeFormBuilder(
          mode: mode,
          meta: _meta(),
          initialData: initialData,
          onSubmit: onSubmit,
          registerSubmit: (fn) => submitFn = fn,
          onFieldChange: (name, value, data, {source = ChangeSource.user}) {
            changed?[name] = value;
            return null;
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return submitFn!;
}

void main() {
  for (final mode in FormBuilderMode.values) {
    group('Rating in a $mode form', () {
      testWidgets(
        'a saved 0.6 still shows 3 of 5 stars after the form settles',
        (tester) async {
          await _pumpForm(
            tester,
            mode: mode,
            initialData: {'score': 0.6},
            onSubmit: (_) {},
          );
          expect(find.byIcon(Icons.star), findsNWidgets(3));
          expect(find.byIcon(Icons.star_border), findsNWidgets(2));
        },
      );

      testWidgets('a saved fraction submits unchanged when untouched', (
        tester,
      ) async {
        Map<String, dynamic>? submitted;
        final submit = await _pumpForm(
          tester,
          mode: mode,
          initialData: {'score': 0.6},
          onSubmit: (d) => submitted = d,
        );
        submit();
        await tester.pumpAndSettle();
        expect(submitted, isNotNull);
        expect(submitted!['score'], 0.6);
      });

      testWidgets('a fraction that arrives as a String still renders', (
        tester,
      ) async {
        await _pumpForm(
          tester,
          mode: mode,
          initialData: {'score': '0.4'},
          onSubmit: (_) {},
        );
        expect(find.byIcon(Icons.star), findsNWidgets(2));
      });

      testWidgets('one tap on the 4th star selects it and submits 0.8', (
        tester,
      ) async {
        Map<String, dynamic>? submitted;
        final changed = <String, dynamic>{};
        final submit = await _pumpForm(
          tester,
          mode: mode,
          initialData: {'score': 0.6},
          onSubmit: (d) => submitted = d,
          changed: changed,
        );
        await tester.tap(find.byIcon(Icons.star_border).first);
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.star), findsNWidgets(4));
        expect(changed['score'], 0.8);
        submit();
        await tester.pumpAndSettle();
        expect(submitted!['score'], 0.8);
      });
    });
  }
}
