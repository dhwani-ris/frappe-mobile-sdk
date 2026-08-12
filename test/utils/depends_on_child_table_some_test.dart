// Child-table `.some(...)` support in depends_on / mandatory_depends_on.
//
// This is a standard Frappe idiom — "show this field when a row in that child
// table picked a particular option", i.e. the `Other … (Specify)` pattern.
// Frappe Desk and Frappe-based SPAs evaluate it with a real JS engine.
//
// Before this branch existed the ` === ` split tore the arrow function in half
// and treated `(doc.x || []).some(r => r.f` as a fieldname, so every such
// expression evaluated false — the dependent field stayed hidden and, being
// hidden, was stripped from the save payload. Free-text "Other" answers were
// unreachable and unsaveable.
//
// Expressions below are verbatim from a real doctype.
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';

void main() {
  bool eval(String expr, Map<String, dynamic> data) =>
      DependsOnEvaluator.evaluate(expr, data);

  group('strict === over a child table', () {
    const expr =
        "eval:(doc.livelihoods || []).some(r => r.livelihood === 'If Others, Then Specify')";

    test('true when a row matches', () {
      expect(
        eval(expr, {
          'livelihoods': [
            {'livelihood': 'Agriculture'},
            {'livelihood': 'If Others, Then Specify'},
          ],
        }),
        isTrue,
      );
    });

    test('false when no row matches', () {
      expect(
        eval(expr, {
          'livelihoods': [
            {'livelihood': 'Agriculture'},
          ],
        }),
        isFalse,
      );
    });

    test('false for an empty table, a missing key, and a non-list', () {
      expect(eval(expr, {'livelihoods': <dynamic>[]}), isFalse);
      expect(eval(expr, {}), isFalse);
      expect(eval(expr, {'livelihoods': 'nonsense'}), isFalse);
    });

    test('ignores rows that are not maps', () {
      expect(
        eval(expr, {
          'livelihoods': ['a', 1, null],
        }),
        isFalse,
      );
    });
  });

  group('the other nine real expressions of the same shape', () {
    const cases = <String, String>{
      'major_crops': 'crop',
      'plantation_resources': 'plantation_resource',
      'forest_resources': 'forest_resource',
      'income_sources': 'income_source',
      'selling_method': 'selling_method',
      'skills': 'skill',
      'constraints': 'key_constraint',
      'opportunities': 'village_opportunity',
      'water_source': 'water_source',
    };

    cases.forEach((table, rowField) {
      test('$table.$rowField', () {
        final expr =
            "eval:(doc.$table || []).some(r => r.$rowField === 'If Others, Then Specify')";
        expect(
          eval(expr, {
            table: [
              {rowField: 'If Others, Then Specify'},
            ],
          }),
          isTrue,
        );
        expect(
          eval(expr, {
            table: [
              {rowField: 'Something else'},
            ],
          }),
          isFalse,
        );
      });
    });
  });

  group('loose .toLowerCase().includes() variant', () {
    // Note the DIFFERENT literal — this master seeds "Please", not "Then".
    const expr =
        "eval:(doc.benchmarked_solutions || []).some(r => (r.benchmarked_solution || '').toLowerCase().includes('others'))";

    test('true on a case-insensitive substring hit', () {
      expect(
        eval(expr, {
          'benchmarked_solutions': [
            {'benchmarked_solution': 'If Others, Please Specify'},
          ],
        }),
        isTrue,
      );
    });

    test('matches regardless of the stored casing', () {
      expect(
        eval(expr, {
          'benchmarked_solutions': [
            {'benchmarked_solution': 'ALL OTHERS'},
          ],
        }),
        isTrue,
      );
    });

    test('false when no row contains the needle', () {
      expect(
        eval(expr, {
          'benchmarked_solutions': [
            {'benchmarked_solution': 'Solar Dryer'},
          ],
        }),
        isFalse,
      );
    });

    test('a null row value does not match and does not throw', () {
      expect(
        eval(expr, {
          'benchmarked_solutions': [
            {'benchmarked_solution': null},
          ],
        }),
        isFalse,
      );
    });
  });

  group('operator and syntax variants', () {
    test('loose == works as well as ===', () {
      expect(
        eval("eval:(doc.t || []).some(r => r.f == 'X')", {
          't': [
            {'f': 'X'},
          ],
        }),
        isTrue,
      );
    });

    test('!== negates', () {
      const expr = "eval:(doc.t || []).some(r => r.f !== 'X')";
      expect(
        eval(expr, {
          't': [
            {'f': 'X'},
          ],
        }),
        isFalse,
      );
      expect(
        eval(expr, {
          't': [
            {'f': 'X'},
            {'f': 'Y'},
          ],
        }),
        isTrue,
      );
    });

    test('the bare form without the || [] guard works', () {
      expect(
        eval("eval:doc.t.some(r => r.f === 'X')", {
          't': [
            {'f': 'X'},
          ],
        }),
        isTrue,
      );
    });

    test('double-quoted literals work', () {
      expect(
        eval('eval:(doc.t || []).some(r => r.f === "X")', {
          't': [
            {'f': 'X'},
          ],
        }),
        isTrue,
      );
    });

    test('an arrow parameter other than `r` works', () {
      expect(
        eval("eval:(doc.t || []).some(row => row.f === 'X')", {
          't': [
            {'f': 'X'},
          ],
        }),
        isTrue,
      );
    });

    test('a trailing semicolon is tolerated', () {
      expect(
        eval("eval:(doc.t || []).some(r => r.f === 'X');", {
          't': [
            {'f': 'X'},
          ],
        }),
        isTrue,
      );
    });
  });

  group('composes with the existing && / || / ! branches', () {
    const some = "(doc.t || []).some(r => r.f === 'X')";

    test('AND with a scalar condition', () {
      expect(
        eval('eval:doc.enabled == 1 && $some', {
          'enabled': 1,
          't': [
            {'f': 'X'},
          ],
        }),
        isTrue,
      );
      expect(
        eval('eval:doc.enabled == 1 && $some', {
          'enabled': 0,
          't': [
            {'f': 'X'},
          ],
        }),
        isFalse,
      );
    });

    test('OR with a scalar condition — the inner || [] is not split', () {
      expect(
        eval('eval:doc.enabled == 1 || $some', {
          'enabled': 0,
          't': [
            {'f': 'X'},
          ],
        }),
        isTrue,
      );
      expect(
        eval('eval:doc.enabled == 1 || $some', {
          'enabled': 0,
          't': <dynamic>[],
        }),
        isFalse,
      );
    });

    test('leading ! negates the whole predicate', () {
      expect(
        eval('eval:!$some', {
          't': [
            {'f': 'X'},
          ],
        }),
        isFalse,
      );
      expect(eval('eval:!$some', {'t': <dynamic>[]}), isTrue);
    });
  });

  group('unrecognised bodies still fall through, not answer falsely', () {
    test('an unsupported arrow body does not claim a verdict of its own', () {
      // `.filter(...).length` is not a shape this branch handles. The point is
      // that it reaches the legacy fallback rather than being answered here;
      // whatever the fallback decides, it must not throw.
      expect(
        () => eval('eval:(doc.t || []).some(r => r.f.startsWith("X") && r.g)', {
          't': [
            {'f': 'X1', 'g': 1},
          ],
        }),
        returnsNormally,
      );
    });
  });
}
