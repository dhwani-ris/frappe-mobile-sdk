// Basic widget test for frappe_mobile_sdk package
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  testWidgets('FrappeFormBuilder renders with minimal meta', (
    WidgetTester tester,
  ) async {
    final meta = DocTypeMeta(
      name: 'Test',
      fields: [DocField(fieldname: 'name', fieldtype: 'Data', label: 'Name')],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(meta: meta, onSubmit: (_) {}),
        ),
      ),
    );

    expect(find.text('Name'), findsAtLeastNWidgets(1));
  });
}
