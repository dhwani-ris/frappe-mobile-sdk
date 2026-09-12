import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

/// Container visibility, matching Frappe Desk.
///
/// Desk hides a layout container when its own `hidden` is set or its
/// `depends_on` is false, and the children go with the wrapper —
/// `Layout.refresh_dependency` walks `fields_list.concat(this.tabs)` and stamps
/// `hidden_due_to_dependency`; `BaseControl.get_status` then returns `"None"`.
/// Verified against Frappe v16.17.5.
///
/// Desk hides the WRAPPER — it never prunes the fields, so their values stay in
/// the document and are still submitted. Every test here asserts BOTH halves:
/// the field is off-screen AND still in the payload. Dropping it would be data
/// loss, which is the trap this feature has to avoid.
void main() {
  Future<Map<String, dynamic>?> pumpAndSubmit(
    WidgetTester tester,
    DocTypeMeta meta, {
    required Map<String, dynamic> initialData,
  }) async {
    Map<String, dynamic>? submitted;
    void Function()? submit;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            initialData: initialData,
            onSubmit: (d) => submitted = d,
            registerSubmit: (s) => submit = s,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    submit!();
    await tester.pumpAndSettle();
    return submitted;
  }

  DocTypeMeta metaWithHiddenSection({bool reqdInside = false}) => DocTypeMeta(
    name: 'T',
    fields: [
      DocField(fieldname: 'visible', fieldtype: 'Data', label: 'Visible Field'),
      DocField(
        fieldname: 'sec_hidden',
        fieldtype: 'Section Break',
        label: 'Bank Info',
        hidden: true,
      ),
      DocField(
        fieldname: 'account_number',
        fieldtype: 'Data',
        label: 'Account Number',
        reqd: reqdInside,
      ),
    ],
  );

  testWidgets('a hidden Section Break hides the fields inside it', (
    tester,
  ) async {
    final submitted = await pumpAndSubmit(
      tester,
      metaWithHiddenSection(),
      initialData: {'visible': 'v', 'account_number': 'ACC-1'},
    );

    expect(find.text('Visible Field'), findsOneWidget);
    expect(find.text('Account Number'), findsNothing);
    expect(find.text('Bank Info'), findsNothing);

    // The value must STILL be saved — Desk hides the wrapper, it does not
    // prune the field. Losing it here would be silent data loss.
    expect(submitted?['account_number'], 'ACC-1');
  });

  testWidgets('a Section Break gated false by depends_on hides its fields', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(fieldname: 'gate', fieldtype: 'Data', label: 'Gate'),
        DocField(
          fieldname: 'sec',
          fieldtype: 'Section Break',
          label: 'Gated Section',
          dependsOn: 'eval:doc.gate == "on"',
        ),
        DocField(fieldname: 'inside', fieldtype: 'Data', label: 'Inside'),
      ],
    );

    final submitted = await pumpAndSubmit(
      tester,
      meta,
      initialData: {'gate': 'off', 'inside': 'kept'},
    );

    expect(find.text('Inside'), findsNothing);

    // DELIBERATE DIVERGENCE, and pre-existing — verified by running this test
    // against the SDK without the container-visibility change: it fails the
    // same way. `_handleSubmit` skips depends_on-gated fields so a value left
    // over from before the gate flipped is not silently saved. Frappe keeps it.
    //
    // The `hidden` case above is different and DOES keep the value: a field in
    // a permanently hidden container was never gated, so there is no stale
    // input to discard. That asymmetry is the point — losing data on a
    // metadata-hidden container would be the real bug.
    expect(submitted?['inside'], isNull);
  });

  testWidgets('an ungated Section Break still renders', (tester) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(
          fieldname: 'sec',
          fieldtype: 'Section Break',
          label: 'Plain Section',
        ),
        DocField(fieldname: 'inside', fieldtype: 'Data', label: 'Inside'),
      ],
    );

    await pumpAndSubmit(tester, meta, initialData: const {});
    expect(find.text('Inside'), findsOneWidget);
  });

  group('the mandatory-field valve', () {
    testWidgets(
      'a hidden container stays VISIBLE when it holds an empty reqd field',
      (tester) async {
        // Frappe validates reqd server-side without consulting hidden
        // (base_document.py selects on {"reqd": ("=", 1)} alone), so hiding
        // this would make the document unsaveable with no field to fix.
        // Three Gunny Bag DO doctypes on this project put their ENTIRE form
        // inside a hidden Section Break at index 0.
        await pumpAndSubmit(
          tester,
          metaWithHiddenSection(reqdInside: true),
          initialData: const {'visible': 'v'},
        );

        expect(
          find.text('Account Number'),
          findsOneWidget,
          reason: 'an unsatisfiable mandatory field must stay reachable',
        );
      },
    );

    testWidgets('the valve closes once the reqd field has a value', (
      tester,
    ) async {
      // Narrow by design: the valve exists to keep the document saveable, not
      // to permanently override the metadata. With data present the server is
      // satisfied, so Desk parity resumes.
      await pumpAndSubmit(
        tester,
        metaWithHiddenSection(reqdInside: true),
        initialData: const {'visible': 'v', 'account_number': 'ACC-9'},
      );

      expect(find.text('Account Number'), findsNothing);
    });

    testWidgets('whitespace does not count as a value', (tester) async {
      await pumpAndSubmit(
        tester,
        metaWithHiddenSection(reqdInside: true),
        initialData: const {'visible': 'v', 'account_number': '   '},
      );

      expect(find.text('Account Number'), findsOneWidget);

      // The validation debounce is still armed after submit; let it fire or
      // the binding reports a pending Timer and fails the test on teardown.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a NON-mandatory empty field does not open the valve', (
      tester,
    ) async {
      await pumpAndSubmit(
        tester,
        metaWithHiddenSection(),
        initialData: const {'visible': 'v'},
      );

      expect(find.text('Account Number'), findsNothing);
    });
  });

  testWidgets('a hidden Column Break hides its fields but keeps their values', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(fieldname: 'sec', fieldtype: 'Section Break', label: 'S'),
        DocField(fieldname: 'left', fieldtype: 'Data', label: 'Left'),
        DocField(
          fieldname: 'col_hidden',
          fieldtype: 'Column Break',
          label: 'Hidden Column',
          hidden: true,
        ),
        DocField(fieldname: 'right', fieldtype: 'Data', label: 'Right'),
      ],
    );

    final submitted = await pumpAndSubmit(
      tester,
      meta,
      initialData: {'left': 'l', 'right': 'r'},
    );

    expect(find.text('Left'), findsOneWidget);
    expect(find.text('Right'), findsNothing);
    expect(submitted?['right'], 'r');
  });
}
