import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

DocTypeMeta _childMeta() => DocTypeMeta.fromJson({
  'name': 'TestChildDoc',
  'fields': [
    {'fieldname': 'size', 'fieldtype': 'Data', 'label': 'Size'},
  ],
});

DocField _field() => DocField.fromJson({
  'fieldname': 'child_table',
  'fieldtype': 'Table',
  'label': 'Child Table',
  'options': 'TestChildDoc',
});

Future<void> _pump(
  WidgetTester tester, {
  required List<dynamic> rows,
  required ValueChanged<dynamic> onChanged,
  required void Function(void Function(Map<String, dynamic>)) capture,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ChildTableField(
            field: _field(),
            value: rows,
            onChanged: onChanged,
            getMeta: (_) async => _childMeta(),
            formBuilder: (m, d, o, {registerSubmit, readOnly = false}) {
              registerSubmit?.call(() {});
              capture(o);
              return const Text('ChildFormContent');
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an added row carries its child doctype', (tester) async {
    List<dynamic>? emitted;
    void Function(Map<String, dynamic>)? submit;
    await _pump(
      tester,
      rows: const [],
      onChanged: (v) => emitted = v as List<dynamic>,
      capture: (o) => submit = o,
    );

    await tester.tap(find.text('Add Row'));
    await tester.pumpAndSettle();
    submit!({'size': '500g'});
    await tester.pumpAndSettle();

    expect((emitted!.first as Map)['doctype'], 'TestChildDoc');
  });

  testWidgets('an edited row keeps its identity and carries the doctype', (
    tester,
  ) async {
    List<dynamic>? emitted;
    void Function(Map<String, dynamic>)? submit;
    await _pump(
      tester,
      rows: const [
        {'size': '500g', 'mobile_uuid': 'u-1'},
      ],
      onChanged: (v) => emitted = v as List<dynamic>,
      capture: (o) => submit = o,
    );

    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    submit!({'size': '750g'});
    await tester.pumpAndSettle();

    final row = emitted!.first as Map;
    expect(row['size'], '750g');
    expect(row['mobile_uuid'], 'u-1');
    expect(row['doctype'], 'TestChildDoc');
  });
}
