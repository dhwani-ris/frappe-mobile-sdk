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
  });
}
