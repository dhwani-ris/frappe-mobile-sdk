import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

void main() {
  testWidgets('onValidationFailed fires when a mandatory field is empty', (
    tester,
  ) async {
    var failedCount = 0;
    var submitCount = 0;
    void Function()? captured;

    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'student_name',
          fieldtype: 'Data',
          idx: 1,
          label: 'Student Name',
          reqd: true,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            initialData: const {},
            onSubmit: (_) => submitCount++,
            onValidationFailed: () => failedCount++,
            registerSubmit: (cb) => captured = cb,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    captured!.call(); // attempt submit with empty mandatory
    await tester.pumpAndSettle();

    expect(failedCount, 1);
    expect(submitCount, 0);
  });

  testWidgets('onValidationFailed does not fire on valid submit', (
    tester,
  ) async {
    var failedCount = 0;
    var submitCount = 0;
    void Function()? captured;

    final meta = DocTypeMeta(
      name: 'Test',
      label: 'Test',
      isTable: false,
      titleField: null,
      searchFields: null,
      fields: [
        DocField(
          fieldname: 'note',
          fieldtype: 'Data',
          idx: 1,
          label: 'Note',
          reqd: false,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: meta,
            initialData: const {'note': 'hello'},
            onSubmit: (_) => submitCount++,
            onValidationFailed: () => failedCount++,
            registerSubmit: (cb) => captured = cb,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    captured!.call(); // valid submit
    await tester.pumpAndSettle();

    expect(failedCount, 0);
    expect(submitCount, 1);
  });
}
