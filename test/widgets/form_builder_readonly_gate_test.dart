import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

/// Regression test for a legacy-mode `depends_on` gate keyed on a READ-ONLY
/// computed field whose value is set programmatically by a caller that shares
/// and mutates the `initialData` map in place.
///
/// This is the BSE Beam pattern: `AdvancedFrappeFormBuilder` passes
/// `initialData: _formData` (a live, in-place mutated map) and its
/// `onFieldChange` handler patches computed READ-ONLY fields (e.g. `qty_variance`
/// on the arrival doctypes) straight into that map. Read-only fields never flow
/// through the form's own `onChanged`, so their programmatic value never reaches
/// the widget's internal `_formData` — only `initialData` has it. Without the
/// read-only overlay in `_evalData`, a gate like `eval:doc.qty_variance > 0`
/// (which reveals the rejection child table so mill/warehouse can record why a
/// shortfall was rejected, enabling the dispute / inconsistency flow) stayed
/// false forever and the section never appeared.
void main() {
  DocTypeMeta gateMeta() => DocTypeMeta(
    name: 'RejectionGateTest',
    fields: <DocField>[
      DocField(fieldname: 'net_weight', fieldtype: 'Data', label: 'Net Weight'),
      DocField(
        fieldname: 'qty_variance',
        fieldtype: 'Float',
        label: 'Qty Variance',
        readOnly: true,
      ),
      DocField(
        fieldname: 'reason_for_rejection',
        fieldtype: 'Data',
        label: 'Reason For Rejection',
        dependsOn: 'eval:doc.qty_variance > 0',
      ),
    ],
  );

  testWidgets(
    'read-only gate reveals the field once the shared initialData crosses > 0',
    (tester) async {
      // Shared, in-place mutated map — mirrors the app passing `initialData: _formData`.
      final data = <String, dynamic>{'qty_variance': 0.0};

      Widget build() => MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(meta: gateMeta(), initialData: data),
        ),
      );

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      // qty_variance == 0 → the gate `qty_variance > 0` is false → field hidden.
      expect(
        find.byKey(const ValueKey('data_reason_for_rejection')),
        findsNothing,
        reason: 'gate is false at qty_variance=0 → rejection field hidden',
      );

      // A handler computes a shortfall and patches the READ-ONLY qty_variance
      // into the SAME initialData map, then the app rebuilds (setState). The
      // value never enters the form's internal _formData (read-only field).
      data['qty_variance'] = 5.0;
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      // The gate must now re-evaluate true from the live initialData overlay.
      expect(
        find.byKey(const ValueKey('data_reason_for_rejection')),
        findsOneWidget,
        reason:
            'read-only qty_variance=5 from the live initialData must unhide the '
            'gated rejection field',
      );
    },
  );
}
