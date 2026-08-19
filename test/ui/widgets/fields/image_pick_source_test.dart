import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/image_pick_source.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';

/// The host hook choosing which sources an image field offers.
void main() {
  final field = DocField(
    fieldname: 'photo',
    fieldtype: 'Attach Image',
    label: 'Photo',
  );

  Future<void> pump(
    WidgetTester tester, {
    ImagePickSource? source,
    dynamic value,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            child: ImageField(
              field: field,
              value: value,
              imagePickSource: source == null ? null : () => source,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ImagePickSource', () {
    testWidgets('null offers BOTH — existing hosts are unaffected', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Gallery'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
    });

    testWidgets('both offers both', (tester) async {
      await pump(tester, source: ImagePickSource.both);
      expect(find.text('Gallery'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
    });

    testWidgets('camera hides the gallery button', (tester) async {
      // The point of camera-only: a stock image cannot be submitted as
      // evidence, so the gallery route must be absent, not merely discouraged.
      await pump(tester, source: ImagePickSource.camera);
      expect(find.text('Gallery'), findsNothing);
      expect(find.text('Camera'), findsOneWidget);
    });

    testWidgets('gallery hides the camera button', (tester) async {
      await pump(tester, source: ImagePickSource.gallery);
      expect(find.text('Gallery'), findsOneWidget);
      expect(find.text('Camera'), findsNothing);
    });
  });

  group('the enum helpers', () {
    test('allowsGallery / allowsCamera', () {
      expect(ImagePickSource.both.allowsGallery, isTrue);
      expect(ImagePickSource.both.allowsCamera, isTrue);
      expect(ImagePickSource.gallery.allowsGallery, isTrue);
      expect(ImagePickSource.gallery.allowsCamera, isFalse);
      expect(ImagePickSource.camera.allowsGallery, isFalse);
      expect(ImagePickSource.camera.allowsCamera, isTrue);
    });
  });

  group('discard', () {
    testWidgets('no remove control when the field is empty', (tester) async {
      await pump(tester);
      expect(find.byTooltip('Remove photo'), findsNothing);
    });

    testWidgets('a remove control appears once there is a value', (
      tester,
    ) async {
      await pump(tester, value: '/files/a.jpg');
      expect(find.byTooltip('Remove photo'), findsOneWidget);
    });

    testWidgets('tapping remove clears the stored value', (tester) async {
      final key = GlobalKey<FormBuilderState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormBuilder(
              key: key,
              child: ImageField(field: field, value: '/files/a.jpg'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Remove photo'));
      await tester.pumpAndSettle();

      expect(key.currentState?.fields['photo']?.value, isNull);
      expect(find.byTooltip('Remove photo'), findsNothing);
    });
  });

  group('value source: user intent vs a late host value', () {
    // These two pull in opposite directions and both must hold. Trusting
    // fieldState alone breaks the first; falling back to the widget value
    // unconditionally breaks the second.
    testWidgets('a value arriving AFTER the first build still renders', (
      tester,
    ) async {
      Widget build(dynamic v) => MaterialApp(
        home: Scaffold(
          body: FormBuilder(
            child: ImageField(field: field, value: v),
          ),
        ),
      );
      await tester.pumpWidget(build(null)); // document not loaded yet
      await tester.pumpAndSettle();
      await tester.pumpWidget(build('/files/late.jpg')); // it arrives
      await tester.pumpAndSettle();

      expect(
        find.byTooltip('Remove photo'),
        findsOneWidget,
        reason: 'an async document load must still populate the field',
      );
    });

    testWidgets('an explicit discard is not undone by the widget value', (
      tester,
    ) async {
      final key = GlobalKey<FormBuilderState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FormBuilder(
              key: key,
              child: ImageField(field: field, value: '/files/a.jpg'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove photo'));
      await tester.pumpAndSettle();

      expect(key.currentState?.fields['photo']?.value, isNull);
      expect(
        find.byTooltip('Remove photo'),
        findsNothing,
        reason: 'the UI must clear too, not just the form value',
      );
    });
  });
}
