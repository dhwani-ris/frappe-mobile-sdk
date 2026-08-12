import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/utils/depends_on_evaluator.dart';

void main() {
  group('spaced operators (existing grammar, regression)', () {
    test('eval:doc.x == 1 true/false', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x == 1', {'x': 1}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x == 1', {'x': 2}), isFalse);
    });

    test('eval:doc.x != "Yes"', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x != "Yes"', {'x': 'No'}),
        isTrue,
      );
    });

    test('bare truthy fieldname', () {
      expect(
        DependsOnEvaluator.evaluate('is_active', {'is_active': 1}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('is_active', {'is_active': 0}),
        isFalse,
      );
    });

    test('includes pattern', () {
      expect(
        DependsOnEvaluator.evaluate('eval:["A","B"].includes(doc.grade)', {
          'grade': 'B',
        }),
        isTrue,
      );
    });

    test('spaced && / ||', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a == 1 && doc.b == 2', {
          'a': 1,
          'b': 2,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a == 1 || doc.b == 2', {
          'a': 0,
          'b': 2,
        }),
        isTrue,
      );
    });
  });

  group('no-space operators (real-world Frappe metas)', () {
    test('eval:doc.x==1', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x==1', {'x': 1}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x==1', {'x': 2}), isFalse);
    });

    test('eval:doc.x!=1', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x!=1', {'x': 2}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x!=1', {'x': 1}), isFalse);
    });

    test('eval:doc.x>=3 and doc.x<=3', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x>=3', {'x': 4}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>=3', {'x': 2}), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:doc.x<=3', {'x': 3}), isTrue);
    });

    test('eval:doc.x>3 and doc.x<3', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x>3', {'x': 4}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x<3', {'x': 2}), isTrue);
    });

    test('strict equality variants', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x==="Yes"', {'x': 'Yes'}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x!=="Yes"', {'x': 'No'}),
        isTrue,
      );
    });

    test('no-space && and ||', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b==2', {
          'a': 1,
          'b': 2,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b==2', {
          'a': 1,
          'b': 3,
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1||doc.b==2', {
          'a': 0,
          'b': 2,
        }),
        isTrue,
      );
    });

    test('mixed spacing', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a ==1 && doc.b== 2', {
          'a': 1,
          'b': 2,
        }),
        isTrue,
      );
    });

    test('unspaced operator set stays intact after quote-aware collapse', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.qty==5', {'qty': 5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.qty>=5', {'qty': 5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.qty!=2', {'qty': 5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b!=2', {
          'a': 1,
          'b': 3,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.a==1&&doc.b!=2', {
          'a': 1,
          'b': 2,
        }),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate('eval:doc.x<=3', {'x': 3}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x<3', {'x': 2}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>3', {'x': 4}), isTrue);
    });

    test('negative numeric literal still parses', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.variance < -1', {'variance': -5}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.variance < -1', {'variance': 0}),
        isFalse,
      );
    });
  });

  group('quote safety', () {
    test('operators inside quoted values are not torn apart', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status=="A && B"', {
          'status': 'A && B',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate("eval:doc.status=='X==Y'", {
          'status': 'X==Y',
        }),
        isTrue,
      );
    });

    test('spaced operators inside quoted values are not torn apart', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.note == "a && b"', {
          'note': 'a && b',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.note == "a && b"', {
          'note': 'a || b',
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.note == "x==y"', {
          'note': 'x==y',
        }),
        isTrue,
      );
    });

    test('internal double space in a quoted literal is preserved (==)', () {
      // Regression: the operator-spacing pass copied quoted contents verbatim,
      // then a global `replaceAll(' {2,}', ' ')` on the finished string undid
      // that and rewrote the INSIDE of string literals. A Select option or Data
      // value carrying two consecutive spaces silently failed its comparison
      // and mis-gated visibility / mandatory / read-only.
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == "In  Progress"', {
          'status': 'In  Progress',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == "In  Progress"', {
          'status': 'In Progress',
        }),
        isFalse,
      );
    });

    test('internal double space in a quoted literal is preserved (!=)', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status != "In  Progress"', {
          'status': 'In  Progress',
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status != "In  Progress"', {
          'status': 'In Progress',
        }),
        isTrue,
      );
    });

    test('leading/trailing spaces inside the quotes are preserved', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == " Draft "', {
          'status': ' Draft ',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == " Draft "', {
          'status': 'Draft',
        }),
        isFalse,
      );
    });
  });

  group('JS arrow functions are not > comparisons', () {
    test('=> is not spaced apart, so the > branch is not taken', () {
      // `r => r.ok` was rewritten to `r = > r.ok`, which made the expression
      // match the ' > ' comparison branch instead of falling through to the
      // truthy fallback as it did before operator spacing was introduced.
      // The fallback looks the expression up with `doc.` stripped, so the key
      // it consults is proof that `=>` survived normalization intact.
      const expr = 'eval:doc.items.some(r => r.ok)';
      expect(
        DependsOnEvaluator.evaluate(expr, {'items.some(r => r.ok)': 1}),
        isTrue,
      );
      // The mangled key the buggy spacing produced is never consulted.
      expect(
        DependsOnEvaluator.evaluate(expr, {'items.some(r = > r.ok)': 1}),
        isFalse,
      );
    });

    test('real > / >= comparisons are unaffected by the arrow guard', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x > 3', {'x': 4}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>3', {'x': 2}), isFalse);
      expect(DependsOnEvaluator.evaluate('eval:doc.x >= 3', {'x': 3}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x>=3', {'x': 2}), isFalse);
    });
  });

  group('leading ! (JS logical NOT)', () {
    test('negates a falsy field to true', () {
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': 0}),
        isTrue,
      );
      expect(DependsOnEvaluator.evaluate('eval:!doc.flag', {}), isTrue);
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': ''}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': false}),
        isTrue,
      );
    });

    test('negates a truthy field to false', () {
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': 1}),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': true}),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.flag', {'flag': 'x'}),
        isFalse,
      );
    });

    test('resolves the framework __islocal flag both ways', () {
      // `read_only_depends_on: eval:!doc.__islocal` is the common Frappe idiom
      // for "lock this field once the document has been saved".
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.__islocal', {'__islocal': 1}),
        isFalse, // unsaved -> not read-only -> editable
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.__islocal', {'__islocal': 0}),
        isTrue, // saved -> read-only
      );
    });

    test('composes with && and ||', () {
      expect(
        DependsOnEvaluator.evaluate(
          'eval:!doc.verified && doc.docstatus === 0',
          {'verified': 0, 'docstatus': 0},
        ),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate(
          'eval:!doc.verified && doc.docstatus === 0',
          {'verified': 1, 'docstatus': 0},
        ),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.a || doc.b', {'a': 1, 'b': 1}),
        isTrue,
      );
    });

    test('!= and !== still reach their own comparison branches', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status !== "Open"', {
          'status': 'Closed',
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status != "Open"', {
          'status': 'Open',
        }),
        isFalse,
      );
      // Unspaced forms go through operator-spacing normalization first.
      expect(DependsOnEvaluator.evaluate('eval:doc.x!=1', {'x': 2}), isTrue);
    });

    test('referencedFields sees through a negation', () {
      expect(DependsOnEvaluator.referencedFields('eval:!doc.__islocal'), {
        '__islocal',
      });
    });
  });

  group('missing docstatus defaults to 0 (Draft)', () {
    test('draft-only comparisons hold when the key is absent', () {
      // In Frappe a document always has a docstatus — 0 while it is a draft —
      // so desk treats eval:doc.docstatus === 0 as true on a new doc. Client
      // form data does not always carry the key.
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus === 0', {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus == 0', {}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus !== 0', {}),
        isFalse,
      );
    });

    test('an explicit docstatus still wins', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus === 0', {
          'docstatus': 1,
        }),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.docstatus === 1', {
          'docstatus': 1,
        }),
        isTrue,
      );
    });

    test('other missing fields are NOT defaulted', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.other === 0', {}), isFalse);
    });
  });

  group('operator-spacing normalization leaves non-expression text alone', () {
    test('an escaped quote does not end the literal early', () {
      // Before: the loop closed on the backslash-escaped quote, so the rest of
      // the string was treated as expression text and operator-spaced.
      expect(
        DependsOnEvaluator.evaluate(r'eval:doc.note == "it\"s ok"', {
          'note': r'it\"s ok',
        }),
        isTrue,
      );
      // A value containing an operator inside an escaped-quote literal must not
      // be re-spaced into a comparison.
      expect(
        DependsOnEvaluator.evaluate(r'eval:doc.note == "a\"b>c"', {
          'note': r'a\"b>c',
        }),
        isTrue,
      );
    });

    test('regex contents cannot change how the expression parses', () {
      // The invariant, asserted without depending on the fallback's exact
      // value: two expressions differing ONLY inside the regex must evaluate
      // identically. Before the fix the operators inside the pattern were
      // spaced into real ' < ' / ' > ' tokens, so editing the pattern changed
      // which branch ran — a bogus comparison instead of the normal fallback.
      const data = {'html': 'anything'};
      final plain = DependsOnEvaluator.evaluate(
        r"eval:doc.html.replace(/x/g, '')",
        data,
      );
      for (final pattern in <String>['<br>', '[a-z>=<]+', '>>', '<=']) {
        expect(
          DependsOnEvaluator.evaluate(
            "eval:doc.html.replace(/$pattern/g, '')",
            data,
          ),
          plain,
          reason: 'pattern "$pattern" must not steer the parse',
        );
      }
    });

    test(
      'a division-position slash does not swallow the rest of the expression',
      () {
        // Only a value position opens a regex; after an identifier `/` is
        // division. If it were treated as a regex opener it would consume through
        // the ' == ', losing the comparison entirely and falling back to a
        // truthiness check on `a` — which would be TRUE here. Asserting false
        // proves the ' == ' survived. (The evaluator does no arithmetic, so
        // `a/2` is simply not a resolvable field.)
        expect(
          DependsOnEvaluator.evaluate('eval:doc.a/2 == 5', {'a': 10}),
          isFalse,
        );
      },
    );

    test('unspaced operators are still normalized', () {
      // The behaviour this normalizer exists for must survive both guards.
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x==1&&doc.y!=2', {
          'x': 1,
          'y': 3,
        }),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x==1&&doc.y!=2', {
          'x': 1,
          'y': 2,
        }),
        isFalse,
      );
    });

    test('a JS arrow is still not spaced into a comparison', () {
      // Regression guard for the pre-existing `=>` handling, re-asserted here
      // because the regex branch now runs before the operator scan. `r => r.x`
      // must not become `r = > r.x`; the observable contract is that the
      // expression stays unparseable and both data shapes agree.
      const expr = 'eval:doc.rows.filter(r => r.qty > 0).length > 0';
      expect(
        DependsOnEvaluator.evaluate(expr, {'rows': <dynamic>[]}),
        DependsOnEvaluator.evaluate(expr, {
          'rows': [
            {'qty': 5},
          ],
        }),
        reason: 'neither shape should be read as a real comparison',
      );
    });

    test('two consecutive spaces inside a literal still survive', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.status == "In  Progress"', {
          'status': 'In  Progress',
        }),
        isTrue,
      );
    });
  });

  group('trailing semicolon in the bare-truthy fallback (regression)', () {
    // Root cause: `_extractFieldName` stripped a leading `doc.` but not a
    // trailing `;`. The comparison branches were unaffected because
    // `_extractValue` (the right-hand operand) already stripped it — only the
    // LEFT operand of a comparison and the whole-expression truthy fallback
    // ever reach `_extractFieldName`, and a `;` can only trail the whole
    // expression, never a left operand. So the bug — and the fix — is
    // reachable only through the truthy fallback, including the fallback
    // reached recursively via the leading-`!` branch below.
    test('eval:!doc.district; matches the real Frappe read_only_depends_on '
        'for "block"', () {
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.district;', {'district': 'D'}),
        isFalse, // district set -> not read-only -> editable
      );
      expect(DependsOnEvaluator.evaluate('eval:!doc.district;', {}), isTrue);
      expect(
        DependsOnEvaluator.evaluate('eval:!doc.district;', {'district': ''}),
        isTrue,
      );
    });

    test('eval:!doc.district || !doc.block; matches read_only_depends_on for '
        '"village" across all four combinations', () {
      bool ro(Map<String, dynamic> d) =>
          DependsOnEvaluator.evaluate('eval:!doc.district || !doc.block;', d);

      expect(ro({'district': 'D', 'block': 'B'}), isFalse);
      expect(ro({'district': 'D', 'block': ''}), isTrue);
      expect(ro({'district': '', 'block': 'B'}), isTrue);
      expect(ro({'district': '', 'block': ''}), isTrue);
    });

    test('eval:doc.some_check; truthy path with trailing semicolon', () {
      expect(
        DependsOnEvaluator.evaluate('eval:doc.some_check;', {'some_check': 1}),
        isTrue,
      );
      expect(
        DependsOnEvaluator.evaluate('eval:doc.some_check;', {'some_check': 0}),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate('eval:doc.some_check;', {}), isFalse);
    });

    test('regression: comparison operators with a trailing ; still work '
        '(already covered by _extractValue, must not regress)', () {
      expect(DependsOnEvaluator.evaluate('eval:doc.x == 1;', {'x': 1}), isTrue);
      expect(
        DependsOnEvaluator.evaluate('eval:doc.x == 1;', {'x': 2}),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate('eval:doc.x != 1;', {'x': 2}), isTrue);
      expect(DependsOnEvaluator.evaluate('eval:doc.x >= 3;', {'x': 3}), isTrue);
      // includes() has its own fully-anchored regex and never reached
      // _extractFieldName's bare-truthy path even before the fix — confirm
      // it is genuinely untouched (no trailing `;` support was added or
      // needed here; that would be a separate, unrequested change).
      expect(
        DependsOnEvaluator.evaluate('eval:["A","B"].includes(doc.grade)', {
          'grade': 'B',
        }),
        isTrue,
      );
    });
  });

  group('extractEvalDocField (regression: trailing ; must not swallow the '
      'complex-expression fallback)', () {
    // Root cause: _extractFieldName now strips a trailing `;`, which made a
    // complex (non-bare) expression that merely ends in `;` look "changed"
    // from its stripped form too, so it was mistaken for a bare `doc.field`
    // reference and returned whole instead of falling through to the regex.
    test('bare eval:doc.x; still takes the fast path', () {
      expect(DependsOnEvaluator.extractEvalDocField('eval:doc.x;'), 'x');
    });

    test('a complex expression ending in ; falls through to the doc.<field> '
        'regex instead of returning the whole expression', () {
      expect(
        DependsOnEvaluator.extractEvalDocField(
          "eval:(doc.category||'').replace(/^prefix\\s*/, '');",
        ),
        'category',
      );
    });
  });

  group('extractEvalDocField only fast-paths a LEGAL fieldname', () {
    // Root cause: the fast path compared the expression against
    // `_extractFieldName`'s output, and that helper just strips a leading
    // `doc.` without checking the remainder is a fieldname. For a multi-term
    // expression the stripped remainder reassembles to the original string, so
    // the equality held and the whole expression came back AS A FIELDNAME.
    // The caller then looked up a field that cannot exist, found nothing, and
    // the link picker silently stopped filtering — it looks like "no filter
    // configured", not like an error, which is why it survived review.
    test('a && b expression returns the FIRST field, not the whole string', () {
      expect(
        DependsOnEvaluator.extractEvalDocField('eval:doc.a && doc.b'),
        'a',
      );
    });

    test('the same without the eval: prefix', () {
      expect(DependsOnEvaluator.extractEvalDocField('doc.a && doc.b'), 'a');
    });

    test('|| and comparison forms also fall through to the regex', () {
      expect(
        DependsOnEvaluator.extractEvalDocField('eval:doc.state || doc.city'),
        'state',
      );
      expect(
        DependsOnEvaluator.extractEvalDocField('eval:doc.status == "Open"'),
        'status',
      );
    });

    test('a trailing-; multi-term expression is not a bare reference', () {
      expect(
        DependsOnEvaluator.extractEvalDocField('eval:doc.a && doc.b;'),
        'a',
      );
    });

    test('a bare reference with surrounding whitespace still fast-paths', () {
      expect(DependsOnEvaluator.extractEvalDocField('eval: doc.x '), 'x');
      expect(DependsOnEvaluator.extractEvalDocField('eval:doc.x ; '), 'x');
    });

    test('a non-doc expression still returns null', () {
      expect(DependsOnEvaluator.extractEvalDocField('eval:1 == 1'), isNull);
    });
  });

  group('onError — the verdict for an expression that THROWS', () {
    // `onError` only fires on a genuine evaluation failure, not on a false
    // condition and not on an expression that merely falls through to the
    // truthy fallback. Reaching it needs a value that throws while being
    // compared, which is what [_ThrowOnEquals] is for. Without such a value
    // this parameter has no test at all — which is how the reactive-mode and
    // mandatory-sweep call sites below shipped taking the wrong default.
    const expr = "eval:doc.a == 'x'";
    final data = <String, dynamic>{'a': _ThrowOnEquals()};

    test('evaluate defaults to TRUE — correct only for depends_on', () {
      expect(DependsOnEvaluator.evaluate(expr, data), isTrue);
    });

    test('evaluate honours onError: false', () {
      expect(DependsOnEvaluator.evaluate(expr, data, onError: false), isFalse);
    });

    test('evaluate2 FORWARDS onError to evaluate', () {
      // The bug: evaluate2 dropped the argument, so `mandatory_depends_on` and
      // `read_only_depends_on` in reactive mode took the `true` default — an
      // unparseable expression made the field required (blocking Save with
      // nothing the user could do) or read-only (permanently uneditable).
      expect(
        DependsOnEvaluator.evaluate2(expr, data, false, onError: false),
        isFalse,
      );
      // Default preserved, so the signature stays source-compatible.
      expect(DependsOnEvaluator.evaluate2(expr, data, false), isTrue);
    });

    test('defaultWhenEmpty still answers an ABSENT expression', () {
      // The two questions are independent: onError must not leak into the
      // null/empty case.
      expect(
        DependsOnEvaluator.evaluate2(null, data, false, onError: false),
        isFalse,
      );
      expect(
        DependsOnEvaluator.evaluate2('', data, true, onError: false),
        isTrue,
      );
    });

    test('a negated failing sub-expression still surfaces as onError', () {
      // `!` inverts the error default on the way down so the `!` on the way
      // back up cancels it — the caller's declared safe answer survives.
      expect(
        DependsOnEvaluator.evaluate(
          "eval:!(doc.a == 'x')",
          data,
          onError: false,
        ),
        isFalse,
      );
      expect(DependsOnEvaluator.evaluate("eval:!(doc.a == 'x')", data), isTrue);
    });

    test('a && / || branch propagates onError to each part', () {
      expect(
        DependsOnEvaluator.evaluate("eval:doc.a == 'x' && doc.b == 1", {
          ...data,
          'b': 1,
        }, onError: false),
        isFalse,
      );
    });
  });
}

/// Throws while being COMPARED, but stringifies normally.
///
/// `==` is the narrowest hook into [DependsOnEvaluator]'s failure path:
/// `_compareValues` compares before it stringifies. Throwing from `toString`
/// instead would also break the callers' own blank-value probes
/// (`v.toString().isEmpty`), which would test the harness rather than the
/// evaluator.
class _ThrowOnEquals {
  @override
  bool operator ==(Object other) => throw StateError('comparison exploded');

  @override
  int get hashCode => 0;

  @override
  String toString() => 'boom';
}
