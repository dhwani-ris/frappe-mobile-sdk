import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';

void main() {
  group('DependsOnEvaluator', () {
    group('existing operators still work', () {
      test('== comparison', () {
        expect(
          DependsOnEvaluator.evaluate("eval:doc.status == 'Yes'", {
            'status': 'Yes',
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate("eval:doc.status == 'Yes'", {
            'status': 'No',
          }),
          isFalse,
        );
      });

      test('!= comparison', () {
        expect(
          DependsOnEvaluator.evaluate("eval:doc.status != 'Yes'", {
            'status': 'No',
          }),
          isTrue,
        );
      });

      test('&& operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.category == 'TypeA' && doc.verified == 'Yes'",
            {'category': 'TypeA', 'verified': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.category == 'TypeA' && doc.verified == 'Yes'",
            {'category': 'TypeA', 'verified': 'No'},
          ),
          isFalse,
        );
      });

      test('|| operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.flag_a == 'Yes' || doc.flag_b == 'Yes'",
            {'flag_a': 'No', 'flag_b': 'Yes'},
          ),
          isTrue,
        );
      });

      test('null/empty expression returns true', () {
        expect(DependsOnEvaluator.evaluate(null, {}), isTrue);
        expect(DependsOnEvaluator.evaluate('', {}), isTrue);
      });

      test('truthy field check', () {
        expect(
          DependsOnEvaluator.evaluate('eval:doc.active', {'active': 'Yes'}),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate('eval:doc.active', {'active': ''}),
          isFalse,
        );
        expect(DependsOnEvaluator.evaluate('eval:doc.active', {}), isFalse);
      });
    });

    group('.includes() array expressions', () {
      test('single-quoted values — match', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category)",
            {'category': 'TypeB'},
          ),
          isTrue,
        );
      });

      test('single-quoted values — no match', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category)",
            {'category': 'TypeC'},
          ),
          isFalse,
        );
      });

      test('single-quoted values — field is null', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['Yes','No'].includes(doc.answer)",
            {},
          ),
          isFalse,
        );
      });

      test('double-quoted values', () {
        expect(
          DependsOnEvaluator.evaluate(
            'eval:["Male","Female"].includes(doc.gender)',
            {'gender': 'Female'},
          ),
          isTrue,
        );
      });

      test('.includes() combined with && operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category) && doc.status == 'Yes'",
            {'category': 'TypeA', 'status': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['TypeA','TypeB'].includes(doc.category) && doc.status == 'Yes'",
            {'category': 'TypeA', 'status': 'No'},
          ),
          isFalse,
        );
      });

      test('.includes() combined with || operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['Admin','Manager'].includes(doc.role) || doc.override == 'Yes'",
            {'role': 'User', 'override': 'Yes'},
          ),
          isTrue,
        );
      });

      test('empty array always false', () {
        expect(
          DependsOnEvaluator.evaluate("eval:[].includes(doc.field)", {
            'field': 'anything',
          }),
          isFalse,
        );
      });
    });

    group('grouping with parens', () {
      test('outer parens around a single AND group are stripped', () {
        expect(
          DependsOnEvaluator.evaluate("eval:(doc.a == 'X' && doc.b == 'Y')", {
            'a': 'X',
            'b': 'Y',
          }),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate("eval:(doc.a == 'X' && doc.b == 'Y')", {
            'a': 'X',
            'b': 'Z',
          }),
          isFalse,
        );
      });

      test('two AND groups joined by || — first true', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(doc.a == 'X' && doc.b == 'Y') || (doc.c == 'Z' && doc.d == 'W')",
            {'a': 'X', 'b': 'Y'},
          ),
          isTrue,
        );
      });

      test('two AND groups joined by || — second true', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(doc.a == 'X' && doc.b == 'Y') || (doc.c == 'Z' && doc.d == 'W')",
            {'c': 'Z', 'd': 'W'},
          ),
          isTrue,
        );
      });

      test('two AND groups joined by || — both false', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(doc.a == 'X' && doc.b == 'Y') || (doc.c == 'Z' && doc.d == 'W')",
            {'a': 'X', 'b': 'NO', 'c': 'Z', 'd': 'NO'},
          ),
          isFalse,
        );
      });

      test('paren group containing .includes mixed with == ', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(['A','B'].includes(doc.cat) && doc.flag == 'Yes')",
            {'cat': 'A', 'flag': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:(['A','B'].includes(doc.cat) && doc.flag == 'Yes')",
            {'cat': 'C', 'flag': 'Yes'},
          ),
          isFalse,
        );
      });

      test('Frappe section_break_presence regression', () {
        // Verbatim from snf household_survey_family_member.json — was hidden
        // on mobile because parens grouping was not respected.
        const expr =
            "eval:(['5 Years to Less than 15 Years','15 Years and Above'].includes(doc.age_grup) && doc.study == 'No')"
            " || (doc.age_grup == '15 Years and Above' && doc.study == 'Yes' && doc.study_cont == 'No' && ['Anganwadi','Primary 1 to 2','Primary 3 to 5'].includes(doc.lst_pssd_clss))";

        // Branch 1: 15+ and study=No → section visible.
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': '15 Years and Above',
            'study': 'No',
          }),
          isTrue,
        );

        // Branch 2: 15+, study=Yes, dropped out at primary → section visible.
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': '15 Years and Above',
            'study': 'Yes',
            'study_cont': 'No',
            'lst_pssd_clss': 'Primary 3 to 5',
          }),
          isTrue,
        );

        // Neither branch matches → section hidden.
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': 'Less than 5 Years',
            'study': 'No',
          }),
          isFalse,
        );
        expect(
          DependsOnEvaluator.evaluate(expr, {
            'age_grup': '15 Years and Above',
            'study': 'Yes',
            'study_cont': 'Yes',
          }),
          isFalse,
        );
      });

      test('nested parens flatten correctly', () {
        expect(
          DependsOnEvaluator.evaluate("eval:((doc.a == 'X'))", {'a': 'X'}),
          isTrue,
        );
      });
    });
  });
}
