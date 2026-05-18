import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/button_field.dart';

Future<void> _pump(
  WidgetTester tester, {
  required DocField field,
  bool enabled = true,
  Future<void> Function(DocField, Map<String, dynamic>)? onPressed,
  Map<String, dynamic>? formData,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ButtonField(
          field: field,
          enabled: enabled,
          onButtonPressed: onPressed,
          formData: formData,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders label as the button text', (tester) async {
    await _pump(
      tester,
      field: DocField(fieldname: 'go', fieldtype: 'Button', label: 'Sync now'),
      onPressed: (_, _) async {},
    );
    expect(find.text('Sync now'), findsOneWidget);
  });

  testWidgets('onButtonPressed receives field + formData on tap', (
    tester,
  ) async {
    DocField? receivedField;
    Map<String, dynamic>? receivedData;
    await _pump(
      tester,
      field: DocField(fieldname: 'go', fieldtype: 'Button', label: 'Go'),
      formData: const {'name': 'X'},
      onPressed: (f, d) async {
        receivedField = f;
        receivedData = d;
      },
    );
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();
    expect(receivedField?.fieldname, 'go');
    expect(receivedData, {'name': 'X'});
  });

  testWidgets('shows CircularProgressIndicator while awaiting the future', (
    tester,
  ) async {
    final completer = Completer<void>();
    await _pump(
      tester,
      field: DocField(fieldname: 'go', fieldtype: 'Button', label: 'Go'),
      onPressed: (_, _) => completer.future,
    );
    await tester.tap(find.byType(ElevatedButton));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('enabled=false disables the button', (tester) async {
    var calls = 0;
    await _pump(
      tester,
      enabled: false,
      field: DocField(fieldname: 'go', fieldtype: 'Button', label: 'Go'),
      onPressed: (_, _) async => calls++,
    );
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );
    expect(calls, 0);
  });

  testWidgets('hidden field renders nothing', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'go',
        fieldtype: 'Button',
        label: 'Go',
        hidden: true,
      ),
    );
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('description renders below the button when present', (
    tester,
  ) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'go',
        fieldtype: 'Button',
        label: 'Go',
        description: 'Click to fire',
      ),
    );
    expect(find.text('Click to fire'), findsOneWidget);
  });
}
