import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/form_builder.dart';

/// Nothing may be locked out by metadata.
///
/// `_buildTabsFor` yields no tabs when a meta is empty or every data field is
/// `hidden`. That used to render a bare "No fields to display", which on a
/// read-only child-table sheet meant the operator could see the row existed but
/// never read it — indistinguishable from a broken feature.
///
/// Reproducer from the field: tapping an `Assaying Parameters Child` row on a
/// submitted Procurement Hundi Verification opened a sheet titled
/// "View Assaying Parameters Child" containing only "No fields to display",
/// while the server's meta had 5 fields with `parameter_name` visible.
void main() {
  Future<void> pump(
    WidgetTester tester,
    DocTypeMeta meta,
    Map<String, dynamic>? initialData,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            initialData: initialData,
            onSubmit: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('an empty meta still shows the values it was handed', (
    tester,
  ) async {
    await pump(
      tester,
      DocTypeMeta(name: 'Assaying Parameters Child', fields: const []),
      {'parameter_name': 'Moisture', 'observed_value': '12.5'},
    );

    expect(find.text('No fields to display'), findsNothing);
    expect(find.textContaining('Layout unavailable'), findsOneWidget);
    expect(find.text('Moisture'), findsOneWidget);
    expect(find.text('12.5'), findsOneWidget);
  });

  testWidgets('a meta of only hidden fields still shows the values', (
    tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'C',
      fields: [
        DocField(fieldname: 'a', fieldtype: 'Data', label: 'A', hidden: true),
        DocField(fieldname: 'b', fieldtype: 'Data', label: 'B', hidden: true),
      ],
    );

    await pump(tester, meta, {'a': 'kept'});

    expect(find.text('kept'), findsOneWidget);
  });

  testWidgets('plumbing keys are not shown as if they were data', (
    tester,
  ) async {
    await pump(tester, DocTypeMeta(name: 'C', fields: const []), {
      'parameter_name': 'Moisture',
      'parent': 'PHV-0001',
      'parenttype': 'Procurement Hundi Verification',
      'parentfield': 'assaying_parameters',
      'idx': 1,
      'docstatus': 1,
      '__islocal': 1,
      'empty': '',
    });

    expect(find.text('Moisture'), findsOneWidget);
    expect(find.text('PHV-0001'), findsNothing);
    expect(find.text('assaying_parameters'), findsNothing);
    expect(find.text('empty'), findsNothing);
  });

  testWidgets(
    'with no meta AND no data it still says so rather than rendering blank',
    (tester) async {
      await pump(tester, DocTypeMeta(name: 'C', fields: const []), const {});
      expect(find.text('No fields to display'), findsOneWidget);
    },
  );
}
