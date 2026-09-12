import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The gap this closes: the parent mandatory sweep judges a `Table` field only
/// by whether the LIST is empty. A table holding rows whose mandatory cells are
/// all null is non-empty, so it passes every client layer and is refused by the
/// server AFTER the POST — where the message carries no field mapping and
/// nothing can scroll the operator to the offending cell.
///
/// The shape that hits it: a client script seeds child rows from a server
/// lookup and leaves their value columns null. The rows exist, so the list is
/// non-empty, and no asterisk or inline error appears anywhere in the form.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  DocTypeMeta parentMeta() => DocTypeMeta(
    name: 'Parent',
    fields: <DocField>[
      DocField(
        fieldname: 'items',
        fieldtype: 'Table',
        label: 'Readings',
        options: 'ChildDoctype',
      ),
    ],
  );

  DocTypeMeta childMeta() => DocTypeMeta(
    name: 'ChildDoctype',
    fields: <DocField>[
      DocField(fieldname: 'parameter', fieldtype: 'Data', label: 'Parameter'),
      DocField(
        fieldname: 'reading',
        fieldtype: 'Data',
        label: 'Reading',
        reqd: true,
      ),
    ],
  );

  Future<void> pump(
    WidgetTester tester, {
    required List<Map<String, dynamic>> rows,
    required void Function(Map<String, dynamic>) onSubmit,
    required void Function() onValidationFailed,
    required void Function(void Function()) registerSubmit,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: parentMeta(),
            initialData: {'items': rows},
            getMeta: (doctype) async => childMeta(),
            onSubmit: onSubmit,
            onValidationFailed: onValidationFailed,
            registerSubmit: registerSubmit,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a row missing a mandatory cell BLOCKS submit', (tester) async {
    Map<String, dynamic>? submitted;
    var failed = false;
    void Function()? submit;

    await pump(
      tester,
      // Non-empty list, so the parent sweep is satisfied — this is exactly the
      // shape that used to reach the server.
      rows: [
        {'parameter': 'P1', 'reading': null},
      ],
      onSubmit: (d) => submitted = d,
      onValidationFailed: () => failed = true,
      registerSubmit: (fn) => submit = fn,
    );

    submit!.call();
    await tester.pumpAndSettle();

    expect(submitted, isNull, reason: 'the POST must not be attempted');
    expect(failed, isTrue);
  });

  testWidgets('the message names the ROW and the FIELD', (tester) async {
    void Function()? submit;
    await pump(
      tester,
      rows: [
        {'parameter': 'P1', 'reading': 'ok'},
        {'parameter': 'P2', 'reading': ''},
      ],
      onSubmit: (_) {},
      onValidationFailed: () {},
      registerSubmit: (fn) => submit = fn,
    );

    submit!.call();
    await tester.pumpAndSettle();

    // Row 2, not row 1 — an operator cannot act on "something is missing".
    expect(find.textContaining('Row #2'), findsWidgets);
    expect(find.textContaining('Reading'), findsWidgets);
  });

  testWidgets('complete rows submit normally', (tester) async {
    Map<String, dynamic>? submitted;
    void Function()? submit;

    await pump(
      tester,
      rows: [
        {'parameter': 'P1', 'reading': '12.5'},
      ],
      onSubmit: (d) => submitted = d,
      onValidationFailed: () {},
      registerSubmit: (fn) => submit = fn,
    );

    submit!.call();
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
  });

  testWidgets('unknown child meta must NOT block the save', (tester) async {
    // Fails OPEN. "We could not load the meta" is not "the row is incomplete";
    // blocking here would strand the operator on a network hiccup.
    Map<String, dynamic>? submitted;
    void Function()? submit;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: parentMeta(),
            initialData: {
              'items': [
                {'parameter': 'P1', 'reading': null},
              ],
            },
            getMeta: (_) => Future.error(Exception('offline')),
            onSubmit: (d) => submitted = d,
            registerSubmit: (fn) => submit = fn,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    submit!.call();
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
  });
}
