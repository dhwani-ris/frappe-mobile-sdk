import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';

DocTypeMeta _meta(List<DocField> f) => DocTypeMeta(name: 'T', fields: f);

/// Throws while being COMPARED, but stringifies normally — drives
/// `DependsOnEvaluator`'s catch without breaking the controller's own
/// blank-value probe, which calls `toString()`.
class _ThrowOnEquals {
  @override
  bool operator ==(Object other) => throw StateError('comparison exploded');

  @override
  int get hashCode => 0;

  @override
  String toString() => 'boom';
}

void main() {
  test('required (reqd) fails validate() when empty, passes when filled', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data', reqd: true)]),
    );
    expect(c.validate(), false);
    expect(c.errorOf('a'), isNotNull);
    c.setValue('a', 'x');
    expect(c.validate(), true);
    expect(c.errorOf('a'), isNull);
    c.dispose();
  });

  test('reqd takes priority over a registered field validator', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data', reqd: true)]),
    );
    c.addFieldValidator('a', (v, _) => 'always-bad');
    c.validate();
    expect(c.errorOf('a'), contains('required')); // reqd wins on empty
    c.dispose();
  });

  test('cross-field validator surfaces an error keyed by field', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'min', fieldtype: 'Int'),
        DocField(fieldname: 'max', fieldtype: 'Int'),
      ]),
    );
    c.addCrossFieldValidator((d) {
      final lo = d['min'], hi = d['max'];
      if (lo != null && hi != null && (lo as num) > (hi as num)) {
        return {'max': 'max < min'};
      }
      return null;
    });
    c.setValue('min', 5);
    c.setValue('max', 3);
    expect(c.validate(), false);
    expect(c.errorOf('max'), 'max < min');
    c.dispose();
  });

  test('validateAsync awaits async validators', () async {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'code', fieldtype: 'Data')]),
    );
    c.addAsyncFieldValidator(
      'code',
      (v, _) async => v == 'taken' ? 'duplicate' : null,
    );
    c.setValue('code', 'taken');
    expect(await c.validateAsync(), false);
    expect(c.errorOf('code'), 'duplicate');
    c.dispose();
  });

  test(
    'required Table field fails when the child list is empty, passes with a row',
    () {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'items', fieldtype: 'Table', reqd: true),
        ]),
      );
      // Regression: an empty child table is `[]`, and `[].toString()` is "[]"
      // (not empty), so the old `v.toString().isEmpty` check never flagged it.
      c.setValue('items', <dynamic>[]);
      expect(c.validate(), false);
      expect(c.errorOf('items'), contains('required'));
      // A row present → satisfied.
      c.setValue('items', <dynamic>[
        {'x': 1},
      ]);
      expect(c.validate(), true);
      expect(c.errorOf('items'), isNull);
      c.dispose();
    },
  );

  // "Missing" must mean the same thing here as in the legacy
  // FrappeFormBuilder mandatory sweep, which is trim-aware — otherwise
  // reactive and legacy mode accept different payloads for the same doctype.
  test('whitespace-only value counts as MISSING for a required field', () {
    final c = FormController(
      meta: _meta([DocField(fieldname: 'a', fieldtype: 'Data', reqd: true)]),
    );
    c.setValue('a', '   ');
    expect(c.validate(), false);
    expect(c.errorOf('a'), contains('required'));
    // A tab/newline-only value is equally blank.
    c.setValue('a', '\t\n');
    expect(c.validate(), false);
    // Real content passes, including content with surrounding whitespace.
    c.setValue('a', '  x  ');
    expect(c.validate(), true);
    expect(c.errorOf('a'), isNull);
    c.dispose();
  });

  test('0 and false stay PRESENT for a required field (Frappe parity)', () {
    final c = FormController(
      meta: _meta([
        DocField(fieldname: 'count', fieldtype: 'Int', reqd: true),
        DocField(fieldname: 'flag', fieldtype: 'Check', reqd: true),
      ]),
    );
    c.setValue('count', 0);
    c.setValue('flag', false);
    expect(c.validate(), true);
    expect(c.errorOf('count'), isNull);
    expect(c.errorOf('flag'), isNull);
    // 0.0 too, so Float/Currency keep working.
    c.setValue('count', 0.0);
    expect(c.validate(), true);
    c.dispose();
  });

  // Reactive mode goes through `DependsOnEvaluator.evaluate2`, which used to
  // drop the `onError` argument and so took the `true` default. That is the one
  // default the contract forbids for these two expressions: erring towards
  // required blocks Save with nothing the user can do about it, and erring
  // towards locked makes the field permanently uneditable. FrappeFormBuilder's
  // `_isFieldRequired` / `_isFieldReadOnly` already passed `false`, so the same
  // field disagreed between the two engines.
  group('an unevaluatable mandatory/read-only expression fails OPEN', () {
    FormController controllerWithBoom() {
      final c = FormController(
        meta: _meta([
          DocField(fieldname: 'a', fieldtype: 'Data'),
          DocField(
            fieldname: 'b',
            fieldtype: 'Data',
            mandatoryDependsOn: "eval:doc.a == 'x'",
          ),
          DocField(
            fieldname: 'c',
            fieldtype: 'Data',
            readOnlyDependsOn: "eval:doc.a == 'x'",
          ),
        ]),
      );
      // Forces the evaluator's failure path: `_compareValues` compares before
      // it stringifies, so this throws exactly where a genuinely unparseable
      // expression would.
      c.setValue('a', _ThrowOnEquals());
      return c;
    }

    test('the field does NOT become required, and validate() passes', () {
      final c = controllerWithBoom();
      expect(c.uiStateOf('b').value.required, isFalse);
      expect(c.validate(), isTrue);
      expect(c.errorOf('b'), isNull);
      c.dispose();
    });

    test('the field does NOT become read-only', () {
      final c = controllerWithBoom();
      expect(c.uiStateOf('c').value.readOnly, isFalse);
      c.dispose();
    });
  });

  test('empty list stays MISSING; null stays MISSING', () {
    final c = FormController(
      meta: _meta([
        DocField(
          fieldname: 'items',
          fieldtype: 'Table MultiSelect',
          reqd: true,
        ),
      ]),
    );
    expect(c.validate(), false); // null
    c.setValue('items', <dynamic>[]);
    expect(c.validate(), false);
    expect(c.errorOf('items'), contains('required'));
    c.setValue('items', <dynamic>[
      {'sector': 'AGRI'},
    ]);
    expect(c.validate(), true);
    c.dispose();
  });
}
