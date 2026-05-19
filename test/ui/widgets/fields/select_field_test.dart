import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/select_field.dart';

Future<void> _pumpSelect(
  WidgetTester tester, {
  required DocField field,
  dynamic value,
  ValueChanged<dynamic>? onChanged,
  GlobalKey<FormBuilderState>? formKey,
}) async {
  final key = formKey ?? GlobalKey<FormBuilderState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: FormBuilder(
          key: key,
          child: SelectField(field: field, value: value, onChanged: onChanged),
        ),
      ),
    ),
  );
}

void main() {
  group('single-select dropdown', () {
    testWidgets('renders newline-separated options as DropdownMenuItems', (
      tester,
    ) async {
      await _pumpSelect(
        tester,
        field: DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          label: 'Status',
          options: 'Open\nClosed\nCancelled',
        ),
      );
      final dropdown = find.byType(FormBuilderDropdown<String>);
      expect(dropdown, findsOneWidget);
      final w = tester.widget<FormBuilderDropdown<String>>(dropdown);
      expect(w.items, hasLength(3));
    });

    testWidgets('initial value is preserved when in options', (tester) async {
      await _pumpSelect(
        tester,
        value: 'Closed',
        field: DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          label: 'Status',
          options: 'Open\nClosed',
        ),
      );
      expect(find.text('Closed'), findsOneWidget);
    });

    testWidgets('initial value not in options falls back to null', (
      tester,
    ) async {
      await _pumpSelect(
        tester,
        value: 'Stale',
        field: DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          label: 'Status',
          options: 'Open\nClosed',
        ),
      );
      // No 'Stale' visible; hint shown.
      expect(find.text('Stale'), findsNothing);
      expect(find.text('Select Status'), findsOneWidget);
    });

    testWidgets('exactly one option → auto-selects and emits onChanged', (
      tester,
    ) async {
      String? emitted;
      await _pumpSelect(
        tester,
        field: DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          label: 'Status',
          options: 'Single',
        ),
        onChanged: (v) => emitted = v as String?,
      );
      await tester.pump();
      expect(find.text('Single'), findsWidgets);
      expect(emitted, 'Single');
    });

    testWidgets('required validator fires on empty submit', (tester) async {
      final formKey = GlobalKey<FormBuilderState>();
      await _pumpSelect(
        tester,
        field: DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          label: 'Status',
          options: 'Open\nClosed',
          reqd: true,
        ),
        formKey: formKey,
      );
      formKey.currentState!.saveAndValidate();
      await tester.pump();
      expect(find.text('Status is required'), findsOneWidget);
    });

    testWidgets('readOnly disables the dropdown', (tester) async {
      await _pumpSelect(
        tester,
        value: 'Open',
        field: DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          label: 'Status',
          options: 'Open\nClosed',
          readOnly: true,
        ),
      );
      final w = tester.widget<FormBuilderDropdown<String>>(
        find.byType(FormBuilderDropdown<String>),
      );
      expect(w.enabled, isFalse);
    });
  });

  group('empty-options fallback', () {
    testWidgets('renders a disabled "No options available" placeholder', (
      tester,
    ) async {
      await _pumpSelect(
        tester,
        field: DocField(
          fieldname: 'status',
          fieldtype: 'Select',
          label: 'Status',
          options: null,
        ),
      );
      expect(find.text('No options available'), findsOneWidget);
    });
  });

  group('multi-select checkbox group', () {
    testWidgets('renders one checkbox per option', (tester) async {
      await _pumpSelect(
        tester,
        field: DocField(
          fieldname: 'tags',
          fieldtype: 'Select',
          label: 'Tags',
          options: 'A\nB\nC',
          allowMultiple: true,
        ),
      );
      expect(find.byType(Checkbox), findsNWidgets(3));
    });

    testWidgets('comma-separated value pre-checks matching options', (
      tester,
    ) async {
      await _pumpSelect(
        tester,
        value: 'A,C',
        field: DocField(
          fieldname: 'tags',
          fieldtype: 'Select',
          label: 'Tags',
          options: 'A\nB\nC',
          allowMultiple: true,
        ),
      );
      final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(boxes[0].value, isTrue);
      expect(boxes[1].value, isFalse);
      expect(boxes[2].value, isTrue);
    });

    testWidgets('emits comma-joined string on selection change', (
      tester,
    ) async {
      String? emitted;
      await _pumpSelect(
        tester,
        value: 'A',
        field: DocField(
          fieldname: 'tags',
          fieldtype: 'Select',
          label: 'Tags',
          options: 'A\nB',
          allowMultiple: true,
        ),
        onChanged: (v) => emitted = v as String?,
      );
      // Tick the "B" checkbox.
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(emitted, 'A,B');
    });
  });
}
