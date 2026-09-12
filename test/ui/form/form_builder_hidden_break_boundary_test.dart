import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

/// `hidden` on a layout break must not dissolve the container BOUNDARY.
///
/// Frappe Desk builds its layout by dispatching on `fieldtype` with no `hidden`
/// filter (`layout.js` `render()`), so a hidden Tab/Section/Column Break still
/// constructs its container (`make_tab` / `make_section` / `make_column`).
/// Verified against Frappe v16.17.5.
///
/// Skipping the break instead reparents every field that follows it into the
/// PREVIOUS container, where it inherits a `depends_on` gate Desk never applies
/// to it — while the save-payload walk in `_handleSubmit`, which keys on
/// `fieldtype` alone, attributes those same fields to the hidden container. Two
/// walks over one meta, two different answers.
///
/// These tests cover the boundary only. A hidden container is still rendered —
/// see the scope note on `_buildTabsFor`.
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

  testWidgets(
    'a field after a hidden Section Break does not inherit the previous '
    "section's depends_on",
    (tester) async {
      // `sec_gated` is false, so if the hidden break is skipped and `after` is
      // reparented into it, `after` vanishes from the form — while the payload
      // walk still attributes `after` to `sec_hidden` (no depends_on) and keeps
      // it. The user never sees a field that is nonetheless saved.
      final meta = DocTypeMeta(
        name: 'T',
        fields: [
          DocField(
            fieldname: 'sec_gated',
            fieldtype: 'Section Break',
            label: 'Gated',
            dependsOn: 'eval:doc.gate == 1',
          ),
          DocField(fieldname: 'inside', fieldtype: 'Data', label: 'Inside'),
          DocField(
            fieldname: 'sec_hidden',
            fieldtype: 'Section Break',
            label: 'Hidden Section',
            hidden: true,
          ),
          DocField(fieldname: 'after', fieldtype: 'Data', label: 'After Break'),
        ],
      );

      final submitted = await pumpAndSubmit(
        tester,
        meta,
        initialData: const {'gate': 0, 'after': 'typed'},
      );

      // `after` belongs to `sec_hidden`, which carries no depends_on, so it
      // must not be gated by the section before it. Container visibility now
      // hides `sec_hidden` itself (Desk parity), so VISIBILITY can no longer
      // stand in for correct parenting — a reparented field and a correctly
      // parented one are both off-screen here.
      //
      // The PAYLOAD is the discriminator, and it is the stronger assertion:
      // reparented into the gated `sec_gated`, `after` would be dropped by the
      // depends_on sweep in `_handleSubmit`. Surviving with its typed value
      // proves it is attributed to `sec_hidden`, which is exactly the
      // render/payload agreement issue #109 was about.
      expect(find.text('Inside'), findsNothing, reason: 'sec_gated is false');
      expect(submitted, isNotNull);
      expect(
        submitted!['after'],
        'typed',
        reason:
            '`after` must be attributed to `sec_hidden` (no depends_on), not '
            'reparented into the gated section before it.',
      );
    },
  );

  testWidgets('a reqd field after a hidden Section Break stays reachable', (
    tester,
  ) async {
    // The shape that makes this urgent: a mandatory field enclosed by a
    // hidden Section Break, with a gated section before it. Reparented, the
    // field is invisible but still swept as mandatory — Save blocks on a
    // field the user cannot see or fill.
    final meta = DocTypeMeta(
      name: 'T',
      fields: [
        DocField(
          fieldname: 'sec_gated',
          fieldtype: 'Section Break',
          label: 'Gated',
          dependsOn: 'eval:doc.gate == 1',
        ),
        DocField(fieldname: 'inside', fieldtype: 'Data', label: 'Inside'),
        DocField(
          fieldname: 'sec_hidden',
          fieldtype: 'Section Break',
          label: 'Hidden Section',
          hidden: true,
        ),
        DocField(
          fieldname: 'must_fill',
          fieldtype: 'Data',
          label: 'Must Fill',
          reqd: true,
        ),
      ],
    );

    await pumpAndSubmit(tester, meta, initialData: const {'gate': 0});

    expect(
      find.text('Must Fill'),
      findsOneWidget,
      reason:
          'a mandatory field the save path validates must be one the form '
          'actually draws',
    );
  });

  testWidgets(
    'a hidden Tab Break does not merge its fields into the previous tab',
    (tester) async {
      final meta = DocTypeMeta(
        name: 'T',
        fields: [
          DocField(fieldname: 't1', fieldtype: 'Tab Break', label: 'Tab One'),
          DocField(fieldname: 'x', fieldtype: 'Data', label: 'Visible X'),
          DocField(
            fieldname: 't_hidden',
            fieldtype: 'Tab Break',
            label: 'Second Tab',
            hidden: true,
          ),
          DocField(fieldname: 'after', fieldtype: 'Data', label: 'After Break'),
        ],
      );

      await pumpAndSubmit(tester, meta, initialData: const {'x': 'X'});

      expect(
        tester.takeException(),
        isNull,
        reason: 'no TabController mismatch',
      );
      expect(find.text('Visible X'), findsOneWidget);
      expect(
        find.text('After Break'),
        findsNothing,
        reason:
            '`after` belongs to the second tab, which is not the selected one — '
            'not to tab one',
      );
    },
  );

  testWidgets(
    'render and payload agree when the hidden break is itself gated',
    (tester) async {
      // Here the hidden Section Break also carries a false depends_on, so the
      // payload walk strips `after`. The form must not draw it as editable —
      // otherwise the user types a value that is discarded at save.
      final meta = DocTypeMeta(
        name: 'T',
        fields: [
          DocField(fieldname: 'sec_a', fieldtype: 'Section Break', label: 'A'),
          DocField(fieldname: 'x', fieldtype: 'Data', label: 'Visible X'),
          DocField(
            fieldname: 'sec_gated_hidden',
            fieldtype: 'Section Break',
            label: 'Gated',
            hidden: true,
            dependsOn: 'eval:doc.gate == 1',
          ),
          DocField(fieldname: 'after', fieldtype: 'Data', label: 'After Break'),
        ],
      );

      final submitted = await pumpAndSubmit(
        tester,
        meta,
        initialData: const {'gate': 0, 'x': 'X', 'after': 'typed'},
      );

      expect(submitted, isNotNull);
      expect(
        submitted!.containsKey('after'),
        isFalse,
        reason: 'the payload walk gates it on the hidden section',
      );
      expect(
        find.text('After Break'),
        findsNothing,
        reason: 'so the form must not offer it for editing',
      );
      expect(find.text('Visible X'), findsOneWidget);
      expect(submitted['x'], 'X');
    },
  );
}
