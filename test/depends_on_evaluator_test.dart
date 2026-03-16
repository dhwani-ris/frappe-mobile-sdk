import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';

void main() {
  group('DependsOnEvaluator', () {
    group('existing operators still work', () {
      test('== comparison', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.study == 'Yes'",
            {'study': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.study == 'Yes'",
            {'study': 'No'},
          ),
          isFalse,
        );
      });

      test('!= comparison', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.study != 'Yes'",
            {'study': 'No'},
          ),
          isTrue,
        );
      });

      test('&& operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.age_grup == '15 Years and Above' && doc.valdy_check == 'Yes'",
            {'age_grup': '15 Years and Above', 'valdy_check': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.age_grup == '15 Years and Above' && doc.valdy_check == 'Yes'",
            {'age_grup': '15 Years and Above', 'valdy_check': 'No'},
          ),
          isFalse,
        );
      });

      test('|| operator', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.case_i == 'Yes' || doc.case_ii == 'Yes'",
            {'case_i': 'No', 'case_ii': 'Yes'},
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
        expect(
          DependsOnEvaluator.evaluate('eval:doc.active', {}),
          isFalse,
        );
      });
    });

    group('.includes() array expressions', () {
      test('single-quoted values — match', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['5 Years to Less than 15 Years','15 Years and Above'].includes(doc.age_grup)",
            {'age_grup': '15 Years and Above'},
          ),
          isTrue,
        );
      });

      test('single-quoted values — no match', () {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['5 Years to Less than 15 Years','15 Years and Above'].includes(doc.age_grup)",
            {'age_grup': 'Less than 1 Year'},
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
            "eval:['5 Years to Less than 15 Years','15 Years and Above'].includes(doc.age_grup) && doc.study == 'Yes'",
            {'age_grup': '15 Years and Above', 'study': 'Yes'},
          ),
          isTrue,
        );
        expect(
          DependsOnEvaluator.evaluate(
            "eval:['5 Years to Less than 15 Years','15 Years and Above'].includes(doc.age_grup) && doc.study == 'Yes'",
            {'age_grup': '15 Years and Above', 'study': 'No'},
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
          DependsOnEvaluator.evaluate(
            "eval:[].includes(doc.field)",
            {'field': 'anything'},
          ),
          isFalse,
        );
      });
    });
  });
}
