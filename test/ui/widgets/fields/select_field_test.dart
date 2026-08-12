import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/base_field.dart';
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

    testWidgets(
      'readOnly with valid options still renders all options, not the '
      'no-options placeholder',
      (tester) async {
        await _pumpSelect(
          tester,
          field: DocField(
            fieldname: 'month',
            fieldtype: 'Select',
            label: 'Month',
            options: '\nJanuary\nFebruary\nMarch',
            readOnly: true,
          ),
        );
        expect(find.text('No options available'), findsNothing);
        final w = tester.widget<FormBuilderDropdown<String>>(
          find.byType(FormBuilderDropdown<String>),
        );
        expect(w.enabled, isFalse);
        expect(w.items.length, 3);
      },
    );
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

  group('full-field tap target', () {
    // The standard form style insets the box content by 16px horizontally.
    // Without the dropdownFullTap redistribution, that 16px margin is a dead
    // zone: a tap on the left edge of the visible box does not open the menu.
    const styledDecoration = InputDecoration(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    );

    Future<void> pumpStyled(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormBuilder(
              child: SelectField(
                field: DocField(
                  fieldname: 'q',
                  fieldtype: 'Select',
                  label: 'Q',
                  options: 'Yes\nNo',
                ),
                style: const FieldStyle(decoration: styledDecoration),
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('tap on the left padding margin opens the menu', (
      tester,
    ) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      // 8px in from the left border — inside the old 16px dead margin.
      await tester.tapAt(Offset(box.left + 8, box.center.dy));
      await tester.pumpAndSettle();
      expect(find.text('No'), findsOneWidget, reason: 'menu should open');
    });

    testWidgets('tap on the center still opens the menu', (tester) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      await tester.tapAt(box.center);
      await tester.pumpAndSettle();
      expect(find.text('No'), findsOneWidget);
    });

    testWidgets('tap near the top edge opens the menu', (tester) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      // 4px below the top border — inside the old vertical padding dead zone.
      await tester.tapAt(Offset(box.center.dx, box.top + 4));
      await tester.pumpAndSettle();
      expect(
        find.text('No'),
        findsOneWidget,
        reason: 'top edge must be tappable',
      );
    });

    testWidgets('tap near the bottom edge opens the menu', (tester) async {
      await pumpStyled(tester);
      final box = tester.getRect(find.byType(InputDecorator).first);
      await tester.tapAt(Offset(box.center.dx, box.bottom - 4));
      await tester.pumpAndSettle();
      expect(
        find.text('No'),
        findsOneWidget,
        reason: 'bottom edge must be tappable',
      );
    });
  });
}
