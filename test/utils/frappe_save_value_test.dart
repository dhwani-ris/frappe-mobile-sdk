import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/utils/frappe_save_value.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// With `roundNumbers` / `roundNumbersOnSave`, Float, Currency and Percent
/// fields with a precision are rounded to it, as Desk's `ControlFloat.parse`
/// does (`flt(value, precision)`). It is OFF by default, which is what
/// 2.0.0-beta.4 sent: rounding only at save, beside client-script values
/// computed from the unrounded figure, makes server checks refuse the save.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  DocField f(String type, int? p) =>
      DocField(fieldname: 'x', fieldtype: type, precision: p);

  test('Frappe rounding with an explicit precision', () {
    expect(frappeRound(12.3456, 2), 12.35);
    expect(frappeRound(0.15, 1), 0.2);
    expect(frappeRound(33.3333, 2), 33.33);
    expect(frappeRound(-2.345, 2), -2.35);
    expect(frappeRound(0.125, 2), 0.13);
  });

  // What a Desk form saves for a field with precision "0": `_round(v, "0")`,
  // recorded by executing Frappe's number_format.js. The even-neighbour rule
  // (2.5 → 2) needs a falsy precision, and the meta's Select string "0" is not.
  test('Frappe rounding at precision 0 rounds a half up, as a Desk form '
      'does', () {
    expect(frappeRound(2.5, 0), 3);
    expect(frappeRound(3.5, 0), 4);
    expect(frappeRound(0.5, 0), 1);
    expect(frappeRound(-2.5, 0), -3);
    expect(frappeRound(2.4, 0), 2);
    expect(frappeRound(-2.6, 0), -3);
  });

  test('with roundNumbers, only numbers in fields with a precision are '
      'rounded', () {
    expect(
      frappeSaveValue(f('Currency', 2), 12.3456, roundNumbers: true),
      12.35,
    );
    expect(
      frappeSaveValue(f('Percent', 2), 33.3333, roundNumbers: true),
      33.33,
    );
    expect(
      frappeSaveValue(f('Float', null), 12.3456, roundNumbers: true),
      12.3456,
    );
    expect(frappeSaveValue(f('Int', 2), 7, roundNumbers: true), 7);
    expect(frappeSaveValue(f('Data', 2), 'x', roundNumbers: true), 'x');
  });

  test('by default numbers are sent as entered (beta.4 behaviour)', () {
    expect(frappeSaveValue(f('Currency', 2), 12.3456), 12.3456);
    // A clamp to another field (flt(owner_total, 6)) must not be rounded UP
    // past the limit it was clamped to: 10.117141 -> 10.12 > 10.117141.
    expect(frappeSaveValue(f('Float', 2), 10.117141), 10.117141);
    // A server-offered remaining figure floored to 3dp stays as offered.
    expect(frappeSaveValue(f('Float', 2), 0.356), 0.356);
  });

  for (final mode in FormBuilderMode.values) {
    Future<Map<String, dynamic>?> save(
      WidgetTester tester, {
      required bool round,
      required double value,
    }) async {
      Map<String, dynamic>? out;
      void Function()? submit;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FrappeFormBuilder(
              meta: DocTypeMeta(
                name: 'Price Entry',
                fields: [
                  DocField(
                    fieldname: 'price',
                    fieldtype: 'Currency',
                    label: 'Price',
                    precision: 2,
                  ),
                ],
              ),
              mode: mode,
              roundNumbersOnSave: round,
              initialData: {'price': value},
              onSubmit: (d) => out = d,
              registerSubmit: (fn) => submit = fn,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      submit!();
      await tester.pumpAndSettle();
      return out;
    }

    testWidgets('$mode: roundNumbersOnSave rounds the saved amount', (
      tester,
    ) async {
      final out = await save(tester, round: true, value: 12.3456);
      expect(out!['price'], 12.35);
    });

    testWidgets('$mode: by default the saved amount is not rounded', (
      tester,
    ) async {
      final out = await save(tester, round: false, value: 0.356);
      expect(out!['price'], 0.356);
    });
  }
}
