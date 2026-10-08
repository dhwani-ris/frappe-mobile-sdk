import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/text_field.dart';

Future<void> _pumpText(
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
          child: TextFieldWidget(
            field: field,
            value: value,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Text fieldtype renders multi-line input (5 maxLines)', (
    tester,
  ) async {
    await _pumpText(
      tester,
      field: DocField(fieldname: 'notes', fieldtype: 'Text', label: 'Notes'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLines, 5);
  });

  testWidgets('Long Text fieldtype also gets 5 maxLines', (tester) async {
    await _pumpText(
      tester,
      field: DocField(fieldname: 'desc', fieldtype: 'Long Text', label: 'Desc'),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLines, 5);
  });

  testWidgets('Small Text gets 3 maxLines', (tester) async {
    await _pumpText(
      tester,
      field: DocField(
        fieldname: 'short',
        fieldtype: 'Small Text',
        label: 'Short',
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLines, 3);
  });

  testWidgets('honors maxLength from field.length', (tester) async {
    await _pumpText(
      tester,
      field: DocField(
        fieldname: 'notes',
        fieldtype: 'Text',
        label: 'Notes',
        length: 200,
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.maxLength, 200);
  });

  testWidgets('onChanged forwards typed text', (tester) async {
    String? emitted;
    await _pumpText(
      tester,
      field: DocField(fieldname: 'notes', fieldtype: 'Text', label: 'Notes'),
      onChanged: (v) => emitted = v as String?,
    );
    await tester.enterText(find.byType(TextField), 'hello there');
    expect(emitted, 'hello there');
  });

  testWidgets('required validator fires on empty submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pumpText(
      tester,
      field: DocField(
        fieldname: 'notes',
        fieldtype: 'Text',
        label: 'Notes',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Notes is required'), findsOneWidget);
  });

  testWidgets('readOnly disables editing', (tester) async {
    await _pumpText(
      tester,
      value: 'fixed',
      field: DocField(
        fieldname: 'notes',
        fieldtype: 'Text',
        label: 'Notes',
        readOnly: true,
      ),
    );
    final tf = tester.widget<TextField>(find.byType(TextField));
    expect(tf.enabled, isFalse);
  });

  group('read-only text box: fixed height, scrollable inside', () {
    final longText = List.generate(20, (i) => 'Line ${i + 1}').join('\n');

    Future<void> pumpInList(
      WidgetTester tester, {
      required String value,
      bool readOnly = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormBuilder(
              child: ListView(
                children: [
                  TextFieldWidget(
                    value: value,
                    field: DocField(
                      fieldname: 'notes',
                      fieldtype: 'Long Text',
                      label: 'Notes',
                      readOnly: readOnly,
                    ),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    ScrollPosition innerPosition(WidgetTester tester) => tester
        .state<EditableTextState>(find.byType(EditableText))
        .widget
        .scrollController!
        .position;

    ScrollPosition pagePosition(WidgetTester tester) =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;

    testWidgets('keeps 5-line height and scrolls the hidden text', (
      tester,
    ) async {
      await pumpInList(tester, value: longText);
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.enabled, isFalse);
      expect(tf.maxLines, 5);
      final heightBefore = tester.getSize(find.byType(TextField)).height;
      expect(innerPosition(tester).maxScrollExtent, greaterThan(0));

      await tester.drag(find.byType(TextField), const Offset(0, -40));
      await tester.pumpAndSettle();

      expect(innerPosition(tester).pixels, greaterThan(0));
      expect(pagePosition(tester).pixels, 0);
      expect(tester.getSize(find.byType(TextField)).height, heightBefore);
    });

    testWidgets('scrolling stops at the end of the text', (tester) async {
      await pumpInList(tester, value: longText);
      // Overshoot by a little: a larger overshoot now scrolls the page (see
      // below) far enough for the ListView to dispose the field.
      final max = innerPosition(tester).maxScrollExtent;
      await tester.drag(find.byType(TextField), Offset(0, -(max + 60)));
      await tester.pumpAndSettle();
      final pos = innerPosition(tester);
      expect(pos.pixels, pos.maxScrollExtent);
    });

    testWidgets('short read-only text leaves page scrolling unchanged', (
      tester,
    ) async {
      await pumpInList(tester, value: 'short');
      await tester.drag(find.byType(TextField), const Offset(0, -100));
      await tester.pumpAndSettle();
      expect(pagePosition(tester).pixels, greaterThan(0));
    });

    testWidgets('editable field is untouched (no injected controller)', (
      tester,
    ) async {
      await pumpInList(tester, value: longText, readOnly: false);
      final tf = tester.widget<TextField>(find.byType(TextField));
      expect(tf.enabled, isTrue);
      expect(tf.maxLines, 5);
      expect(tf.scrollController, isNull);
    });

    testWidgets('drag past the end of the text scrolls the page', (
      tester,
    ) async {
      await pumpInList(tester, value: longText);
      final max = innerPosition(tester).maxScrollExtent;
      await tester.drag(find.byType(TextField), Offset(0, -(max + 60)));
      await tester.pumpAndSettle();
      final inner = innerPosition(tester);
      expect(inner.pixels, inner.maxScrollExtent);
      expect(pagePosition(tester).pixels, greaterThan(0));
    });

    testWidgets('drag down at the top of the text scrolls the page back', (
      tester,
    ) async {
      await pumpInList(tester, value: longText);
      pagePosition(tester).jumpTo(40);
      await tester.pumpAndSettle();
      expect(innerPosition(tester).pixels, 0);

      await tester.drag(find.byType(TextField), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(innerPosition(tester).pixels, 0);
      expect(pagePosition(tester).pixels, lessThan(40));
    });
  });

  group('flipping read-only keeps the same form field', () {
    final longText = List.generate(20, (i) => 'Line ${i + 1}').join('\n');

    Future<StateSetter> pumpFlippable(
      WidgetTester tester, {
      required GlobalKey<FormBuilderState> formKey,
      required ValueNotifier<bool> readOnly,
      required String value,
    }) async {
      late StateSetter setOuter;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormBuilder(
              key: formKey,
              child: StatefulBuilder(
                builder: (context, setState) {
                  setOuter = setState;
                  return ListView(
                    children: [
                      TextFieldWidget(
                        // The parent never feeds typed text back into
                        // `value`, so only a surviving field keeps it.
                        value: value,
                        field: DocField(
                          fieldname: 'notes',
                          fieldtype: 'Long Text',
                          label: 'Notes',
                          readOnly: readOnly.value,
                        ),
                      ),
                      const SizedBox(height: 2000),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return setOuter;
    }

    testWidgets('typed value and field state survive editable <-> read-only', (
      tester,
    ) async {
      final formKey = GlobalKey<FormBuilderState>();
      final readOnly = ValueNotifier(false);
      final setOuter = await pumpFlippable(
        tester,
        formKey: formKey,
        readOnly: readOnly,
        value: 'initial',
      );
      final fieldState = tester.state(find.byType(FormBuilderTextField));

      await tester.enterText(find.byType(TextField), 'typed by user');
      await tester.pump();

      setOuter(() => readOnly.value = true);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(
        identical(tester.state(find.byType(FormBuilderTextField)), fieldState),
        isTrue,
      );
      expect(find.text('typed by user'), findsOneWidget);
      expect(formKey.currentState!.instantValue['notes'], 'typed by user');

      setOuter(() => readOnly.value = false);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(
        identical(tester.state(find.byType(FormBuilderTextField)), fieldState),
        isTrue,
      );
      expect(find.text('typed by user'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).scrollController,
        isNull,
      );
    });

    testWidgets('long text becomes scrollable after flipping to read-only', (
      tester,
    ) async {
      final formKey = GlobalKey<FormBuilderState>();
      final readOnly = ValueNotifier(false);
      final setOuter = await pumpFlippable(
        tester,
        formKey: formKey,
        readOnly: readOnly,
        value: longText,
      );

      setOuter(() => readOnly.value = true);
      await tester.pumpAndSettle();

      await tester.drag(find.byType(TextField), const Offset(0, -40));
      await tester.pumpAndSettle();
      final inner = tester
          .state<EditableTextState>(find.byType(EditableText))
          .widget
          .scrollController!
          .position;
      expect(inner.pixels, greaterThan(0));
    });
  });
}
