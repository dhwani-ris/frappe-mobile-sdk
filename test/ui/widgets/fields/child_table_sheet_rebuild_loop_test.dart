import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

/// A host form builder that registers its submit callback from inside its own
/// build, which is the normal contract — the callback is a closure over the
/// form's state, so it is recreated on every build.
class _RegisteringForm extends StatelessWidget {
  const _RegisteringForm({required this.registerSubmit});
  final void Function(void Function())? registerSubmit;

  @override
  Widget build(BuildContext context) {
    registerSubmit?.call(() {});
    return const SizedBox.shrink();
  }
}

void main() {
  testWidgets('the row sheet settles when the host registers submit on build', (
    WidgetTester tester,
  ) async {
    final childMeta = DocTypeMeta.fromJson({
      'name': 'TestChildDoc',
      'fields': [
        {'fieldname': 'child_data', 'fieldtype': 'Data', 'label': 'Child Data'},
      ],
    });
    final field = DocField.fromJson({
      'fieldname': 'child_table',
      'fieldtype': 'Table',
      'label': 'Child Table',
      'options': 'TestChildDoc',
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChildTableField(
            field: field,
            value: const [
              {'child_data': 'Row 1'},
            ],
            onChanged: (_) {},
            getMeta: (_) async => childMeta,
            formBuilder:
                (meta, data, onSubmit, {registerSubmit, readOnly = false}) =>
                    _RegisteringForm(registerSubmit: registerSubmit),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ListTile).first);

    // The regression: an unconditional setState per registration re-entered
    // formBuilder, which registered again, so a frame was always scheduled and
    // this call never returned.
    await tester.pumpAndSettle();

    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
