import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/image_pick_source.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/image_field.dart';

/// The Gallery/Camera action row on narrow screens.
///
/// The buttons were unconstrained children of a `Row`. An unconstrained child
/// is laid out at its FULL intrinsic width, so once both buttons were shown the
/// row exceeded the viewport on small phones and Flutter painted the overflow
/// stripes across the field. 360dp-wide devices are common, and a large OS font
/// scale narrows the usable width further.
void main() {
  final field = DocField(
    fieldname: 'photo',
    fieldtype: 'Attach Image',
    label: 'Photo',
  );

  /// Widths the field must survive. 320dp is the narrowest mainstream phone;
  /// 360dp is the most common Android width.
  const widths = <double>[320, 360, 412];

  Future<Object?> pumpAt(
    WidgetTester tester,
    double width, {
    double textScale = 1.0,
  }) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: FormBuilder(
              child: ImageField(
                field: field,
                imagePickSource: () => ImagePickSource.both,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.takeException();
  }

  group('ImageField action row on narrow screens', () {
    for (final width in widths) {
      testWidgets('lays out without overflow at ${width.toInt()}dp', (
        tester,
      ) async {
        final exception = await pumpAt(tester, width);
        expect(
          exception,
          isNull,
          reason:
              'Gallery + Camera overflowed the row at ${width.toInt()}dp: '
              '$exception',
        );
        // Both actions must still be reachable — shrinking must not drop one.
        expect(find.text('Gallery'), findsOneWidget);
        expect(find.text('Camera'), findsOneWidget);
      });
    }

    testWidgets('survives a large OS text scale on a narrow screen', (
      tester,
    ) async {
      // Width scaling and the OS font setting compound: the row is at its
      // narrowest exactly when the labels are at their widest.
      final exception = await pumpAt(tester, 320, textScale: 1.3);
      expect(
        exception,
        isNull,
        reason: 'Action row overflowed at 320dp with textScale 1.3: $exception',
      );
    });
  });
}
