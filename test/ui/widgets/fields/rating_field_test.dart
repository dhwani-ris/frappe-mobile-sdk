import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/ui/widgets/fields/rating_field.dart';

Future<void> _pump(
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
          child: RatingField(field: field, value: value, onChanged: onChanged),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders 5 stars by default', (tester) async {
    await _pump(
      tester,
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star_border), findsNWidgets(5));
  });

  testWidgets('renders 10 stars when options=10', (tester) async {
    await _pump(
      tester,
      field: DocField(
        fieldname: 'r',
        fieldtype: 'Rating',
        label: 'Rate',
        options: '10',
      ),
    );
    expect(
      find.byIcon(Icons.star_border).evaluate().length +
          find.byIcon(Icons.star).evaluate().length,
      10,
    );
  });

  testWidgets('value=3 (int) fills 3 stars', (tester) async {
    await _pump(
      tester,
      value: 3,
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star), findsNWidgets(3));
    expect(find.byIcon(Icons.star_border), findsNWidgets(2));
  });

  testWidgets('value="4" (string) parses and fills 4 stars', (tester) async {
    await _pump(
      tester,
      value: '4',
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star), findsNWidgets(4));
  });

  // Frappe stores a Rating as a 0..1 fraction (stars / max_stars), so tapping
  // the 4th of 5 stars must emit 0.8 — not the star count.
  testWidgets('tapping the 4th of 5 stars emits the 0.8 fraction', (
    tester,
  ) async {
    dynamic emitted;
    await _pump(
      tester,
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
      onChanged: (v) => emitted = v,
    );
    await tester.tap(find.byIcon(Icons.star_border).at(3));
    await tester.pump();
    expect(emitted, 0.8);
  });

  testWidgets('tapping the 3rd of 10 stars emits 0.3', (tester) async {
    dynamic emitted;
    await _pump(
      tester,
      field: DocField(
        fieldname: 'r',
        fieldtype: 'Rating',
        label: 'Rate',
        options: '10',
      ),
      onChanged: (v) => emitted = v,
    );
    await tester.tap(find.byIcon(Icons.star_border).at(2));
    await tester.pump();
    expect(emitted, 0.3);
  });

  testWidgets('a web-authored 0.6 renders 3 of 5 stars (was zero before)', (
    tester,
  ) async {
    await _pump(
      tester,
      value: 0.6,
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star), findsNWidgets(3));
    expect(find.byIcon(Icons.star_border), findsNWidgets(2));
  });

  testWidgets('a stored fraction as String parses too', (tester) async {
    await _pump(
      tester,
      value: '0.8',
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
    );
    expect(find.byIcon(Icons.star), findsNWidgets(4));
  });

  testWidgets('re-tapping the last filled star clears the rating to 0', (
    tester,
  ) async {
    dynamic emitted;
    await _pump(
      tester,
      value: 0.6, // 3 of 5 filled
      field: DocField(fieldname: 'r', fieldtype: 'Rating', label: 'Rate'),
      onChanged: (v) => emitted = v,
    );
    await tester.tap(find.byIcon(Icons.star).at(2)); // the 3rd, currently last
    await tester.pump();
    expect(emitted, 0.0);
  });

  group('pure scale conversions', () {
    test('starsFromStored maps the fraction onto the star count', () {
      expect(RatingField.starsFromStored(0.6, 5), 3);
      expect(RatingField.starsFromStored(1, 5), 5);
      expect(RatingField.starsFromStored(0, 5), 0);
      expect(RatingField.starsFromStored(null, 5), 0);
      expect(RatingField.starsFromStored(0.35, 10), 4); // rounds
    });

    test('tolerates a legacy value already written as a star count', () {
      // Pre-fix mobile wrote ints 1..5. Reading one back must not overflow.
      expect(RatingField.starsFromStored(3, 5), 3);
      expect(RatingField.starsFromStored(5, 5), 5);
    });

    test('storedFromStars is the inverse', () {
      expect(RatingField.storedFromStars(3, 5), 0.6);
      expect(RatingField.storedFromStars(0, 5), 0.0);
      expect(RatingField.storedFromStars(10, 10), 1.0);
    });

    test('maxRatingFor defaults to 5 and reads options', () {
      expect(RatingField.maxRatingFor(null), 5);
      expect(RatingField.maxRatingFor(''), 5);
      expect(RatingField.maxRatingFor('10'), 10);
      expect(RatingField.maxRatingFor('bogus'), 5);
    });
  });

  testWidgets('readOnly stars do not respond to taps', (tester) async {
    int? emitted;
    await _pump(
      tester,
      value: 2,
      field: DocField(
        fieldname: 'r',
        fieldtype: 'Rating',
        label: 'Rate',
        readOnly: true,
      ),
      onChanged: (v) => emitted = v as int?,
    );
    await tester.tap(find.byIcon(Icons.star_border).first);
    await tester.pump();
    expect(emitted, isNull);
  });

  testWidgets('required validator fires on null submit', (tester) async {
    final formKey = GlobalKey<FormBuilderState>();
    await _pump(
      tester,
      field: DocField(
        fieldname: 'r',
        fieldtype: 'Rating',
        label: 'Rate',
        reqd: true,
      ),
      formKey: formKey,
    );
    formKey.currentState!.saveAndValidate();
    await tester.pump();
    expect(find.text('Rate is required'), findsOneWidget);
  });
}
