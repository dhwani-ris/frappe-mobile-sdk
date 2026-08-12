// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/foundation.dart';

/// Evaluates Frappe `depends_on` / `mandatory_depends_on` expressions.
///
/// **Trust boundary:** expressions evaluated here come from server-side
/// DocType meta configured by Frappe admins, not from end-user input. This
/// evaluator is NOT sandboxed — do not pass user-supplied strings to
/// [evaluate].
class DependsOnEvaluator {
  /// Returns the set of fieldnames an expression references. Used to build the
  /// reverse-dependency graph. Returns an EMPTY set for a non-null, non-empty
  /// expression it cannot parse — callers treat that as "subscribe to all"
  /// (see DependencyGraph fallback). A bare `field_name` (Frappe truthy form)
  /// resolves to {field_name}.
  static Set<String> referencedFields(String? expression) {
    if (expression == null || expression.trim().isEmpty) return const {};
    var expr = expression.trim();
    if (expr.startsWith('eval:')) expr = expr.substring(5).trim();

    final docRefs = RegExp(
      r'doc\.(\w+)',
    ).allMatches(expr).map((m) => m.group(1)!).toSet();
    if (docRefs.isNotEmpty) return docRefs;

    // No `doc.` tokens: a bare identifier is the Frappe truthy form.
    final bare = RegExp(r'^(\w+)$').firstMatch(expr);
    if (bare != null) return {bare.group(1)!};

    return const {}; // unparseable -> caller falls back to subscribe-all
  }

  /// Like [evaluate] but returns [defaultWhenEmpty] for a null/empty expression.
  /// `depends_on` defaults visible=true; `mandatory_depends_on` /
  /// `read_only_depends_on` must default false when absent.
  ///
  /// [onError] is forwarded to [evaluate] and answers an expression that is
  /// PRESENT but unparseable — a different question from [defaultWhenEmpty],
  /// which answers an ABSENT one. It is a named optional defaulting to `true`
  /// so the signature stays source-compatible (this file is exported from the
  /// package barrel), but callers gating MANDATORY or READ-ONLY must pass
  /// `false`: without it a `mandatory_depends_on` that fails to parse makes the
  /// field required and blocks the save with nothing the user can do about it,
  /// and a `read_only_depends_on` that fails to parse makes the field
  /// permanently uneditable. See [evaluate].
  static bool evaluate2(
    String? expr,
    Map<String, dynamic> data,
    bool defaultWhenEmpty, {
    bool onError = true,
  }) => (expr == null || expr.isEmpty)
      ? defaultWhenEmpty
      : evaluate(expr, data, onError: onError);

  /// Comparison / boolean operators, longest first so `===`/`!==`/`>=`/`<=`
  /// are matched before their shorter substrings tear them apart.
  static final RegExp _opPattern = RegExp(r'===|!==|==|!=|>=|<=|&&|\|\||>|<');

  /// Frappe admins write `doc.x==1&&doc.y!=2` as often as the spaced form,
  /// but every comparison branch below splits on SPACED operators only —
  /// unspaced expressions silently fell through to the truthy fallback and
  /// mis-gated visibility / mandatory / read-only everywhere. Normalize
  /// spacing once up front; the contents of a quoted value come out
  /// byte-identical to the way they went in.
  /// True when a `/` at [i] opens a regex literal rather than acting as
  /// division. Standard JS heuristic: a regex can only start where a value is
  /// expected, i.e. at the beginning or right after an operator / opening
  /// bracket / comma. After an identifier, `)`, `]` or a literal it is division.
  ///
  /// Needed because `_normalizeOperatorSpacing` would otherwise space the
  /// operators INSIDE a pattern — `.replace(/<br>/g, '')` became
  /// `.replace(/ < br > /g, '')`, which then matched the `' < '` comparison
  /// branch and returned a definite wrong answer instead of falling through to
  /// the truthy fallback. Frappe `link_filters` / `depends_on` expressions do
  /// carry `.replace(/…/, …)` in practice, so this is reachable.
  static bool _opensRegexLiteral(String expr, int i) {
    for (var j = i - 1; j >= 0; j--) {
      final c = expr[j];
      if (c == ' ') continue;
      return !(RegExp(r'[A-Za-z0-9_$)\]]').hasMatch(c));
    }
    return true; // start of expression
  }

  static String _normalizeOperatorSpacing(String expr) {
    final buf = StringBuffer();
    String? quote;
    // True when the buffer already ends with a space written OUTSIDE a quoted
    // literal, i.e. the next space would be redundant. Redundant spaces are
    // collapsed here, character by character, instead of by a global
    // `replaceAll(' {2,}', ' ')` over the finished string: a global collapse
    // also rewrites the INSIDE of string literals, so a Select option or Data
    // value carrying two consecutive spaces ("In  Progress") could never match
    // its own form data. Starts true so leading spaces are dropped, which the
    // closing trim() would do anyway.
    bool pendingSpace = true;
    for (var i = 0; i < expr.length; i++) {
      final ch = expr[i];
      if (quote != null) {
        // Inside a quoted literal: copy verbatim, runs of spaces included.
        buf.write(ch);
        // A backslash escapes the next character, so `"it\"s"` does NOT close
        // here. Without this the literal ended early and the remainder — real
        // text, not an expression — got operator-spaced.
        if (ch == r'\' && i + 1 < expr.length) {
          buf.write(expr[i + 1]);
          i++;
          pendingSpace = false;
          continue;
        }
        if (ch == quote) quote = null;
        pendingSpace = false;
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        buf.write(ch);
        pendingSpace = false;
        continue;
      }
      // Regex literal: copy through to the closing unescaped `/` (plus flags)
      // so operators inside the pattern are left alone. A character class may
      // contain an unescaped `/`, so track it.
      if (ch == '/' && _opensRegexLiteral(expr, i)) {
        buf.write(ch);
        var inClass = false;
        var j = i + 1;
        for (; j < expr.length; j++) {
          final rc = expr[j];
          buf.write(rc);
          if (rc == r'\' && j + 1 < expr.length) {
            buf.write(expr[j + 1]);
            j++;
            continue;
          }
          if (rc == '[') {
            inClass = true;
          } else if (rc == ']') {
            inClass = false;
          } else if (rc == '/' && !inClass) {
            break;
          }
        }
        i = j;
        pendingSpace = false;
        continue;
      }
      if (ch == ' ') {
        if (!pendingSpace) {
          buf.write(ch);
          pendingSpace = true;
        }
        continue;
      }
      final op = _opPattern.matchAsPrefix(expr, i)?.group(0);
      // `=>` is a JS arrow, not a comparison. Spacing the bare `>` that follows
      // an `=` turns `r => r.x` into `r = > r.x`, which then matches the ' > '
      // comparison branch instead of falling through to the truthy fallback as
      // it did before spacing normalization existed. `>=`/`<=` are unaffected:
      // the longest-first alternation matches them whole, so `op` is never a
      // bare `>` there.
      final isArrowTail = op == '>' && i > 0 && expr[i - 1] == '=';
      if (op != null && !isArrowTail) {
        if (!pendingSpace) buf.write(' ');
        buf.write(op);
        buf.write(' ');
        pendingSpace = true;
        i += op.length - 1;
        continue;
      }
      buf.write(ch);
      pendingSpace = false;
    }
    // Safe: trim() only touches the ends of the whole expression.
    return buf.toString().trim();
  }

  /// Evaluate depends_on expression
  /// Supports: eval:doc.field == value, eval:doc.field != value, etc.
  /// Operator spacing is normalized, so `doc.field==value` works too.
  /// [onError] is the verdict returned when the expression cannot be evaluated
  /// at all (a genuine parse/eval failure, not a false condition).
  ///
  /// It must differ by caller. For `depends_on`, `true` is safe — show the field
  /// rather than silently hide data. For `mandatory_depends_on` the same default
  /// is harmful: an unparseable expression would mark the field required and
  /// block the save with nothing the user can do about it, so that caller passes
  /// `false`. Same for `read_only_depends_on`, where erring towards locked would
  /// make a field permanently uneditable.
  static bool evaluate(
    String? expression,
    Map<String, dynamic> formData, {
    bool onError = true,
  }) {
    if (expression == null || expression.isEmpty) return true;

    // Remove eval: prefix if present
    String expr = expression.trim();
    if (expr.startsWith('eval:')) {
      expr = expr.substring(5).trim();
    }
    // Strip outer parens left over from grouped expressions like
    // `(A && B) || (C && D)` — after the && / || split each fragment
    // arrives wrapped in its own parens and would otherwise leak `(`/`)`
    // into _extractFieldName / _extractValue.
    expr = _stripOuterParens(expr);
    expr = _normalizeOperatorSpacing(expr);

    // Simple evaluation for common patterns
    // eval:doc.field == value
    // eval:doc.field != value
    // eval:doc.field > value
    // eval:doc.field < value
    // eval:doc.field >= value
    // eval:doc.field <= value

    try {
      // Handle && (AND) operator — split outside brackets to avoid breaking .includes([...])
      final andParts = _splitOutsideBrackets(expr, ' && ');
      if (andParts.length > 1) {
        return andParts.every(
          (part) => evaluate(part.trim(), formData, onError: onError),
        );
      }

      // Handle || (OR) operator — same bracket-aware splitting
      final orParts = _splitOutsideBrackets(expr, ' || ');
      if (orParts.length > 1) {
        return orParts.any(
          (part) => evaluate(part.trim(), formData, onError: onError),
        );
      }

      // Handle a leading `!` (JS logical NOT), e.g. `!doc.__islocal` — the
      // standard Frappe idiom for `read_only_depends_on` meaning "lock this
      // field once the document has been saved". Without this branch the
      // expression fell through to the truthy fallback below, which looked up
      // the literal key `"!doc.__islocal"`, found nothing, and returned false —
      // so such fields never became read-only.
      //
      // Placed AFTER the && / || splits so `!doc.a && doc.b` splits first, and
      // guarded against `!=` / `!==` so those still reach their own branches.
      if (expr.startsWith('!') &&
          !expr.startsWith('!=') &&
          !expr.startsWith('!==')) {
        // Invert the error default too, so that a failure inside the negated
        // sub-expression still surfaces as [onError] after the `!`.
        return !evaluate(expr.substring(1).trim(), formData, onError: !onError);
      }

      // Handle child-table membership:
      //   (doc.<table> || []).some(r => r.<field> === '<literal>')
      //   (doc.<table> || []).some(r => (r.<field> || '').toLowerCase().includes('<literal>'))
      //
      // A standard Frappe idiom for "show this field when a row in that child
      // table selected a particular option" — the `Other … (Specify)` pattern.
      // Frappe Desk and the web SPA both evaluate it with a real JS engine.
      // Without this branch the ` === ` split below tore the arrow function in
      // half, took `(doc.x || []).some(r => r.f` as a FIELDNAME, looked it up,
      // found nothing, and returned false — so such fields were permanently
      // hidden and (being hidden) stripped from the save payload.
      //
      // Placed after the && / || / ! branches so composite expressions split
      // first. Both helpers above are paren-aware, so the ` || ` inside
      // `(doc.x || [])` is not mistaken for a logical OR.
      final someResult = _evaluateChildTableSome(expr, formData);
      if (someResult != null) return someResult;

      // Handle [values].includes(doc.field) pattern
      final includesMatch = RegExp(
        r"^\[(.*)?\]\.includes\(doc\.(\w+)\)$",
      ).firstMatch(expr);
      if (includesMatch != null) {
        final arrayContent = includesMatch.group(1) ?? '';
        final fieldName = includesMatch.group(2)!;
        final values = _parseArrayValues(arrayContent);
        final actual = _fieldValue(formData, fieldName);
        if (actual == null) return false;
        return values.contains(actual.toString());
      }

      // Handle === comparison (JS strict equality — semantically same as == in Dart).
      // Must be checked BEFORE == since === contains == as a substring.
      if (expr.contains(' === ')) {
        final parts = expr.split(' === ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '==');
        }
      }

      // Handle !== comparison (JS strict inequality — semantically same as != in Dart).
      // Must be checked BEFORE != since !== contains != as a substring.
      if (expr.contains(' !== ')) {
        final parts = expr.split(' !== ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '!=');
        }
      }

      // Handle == comparison
      if (expr.contains(' == ')) {
        final parts = expr.split(' == ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '==');
        }
      }

      // Handle != comparison
      if (expr.contains(' != ')) {
        final parts = expr.split(' != ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '!=');
        }
      }

      // Handle >= comparison (before > to avoid false match)
      if (expr.contains(' >= ')) {
        final parts = expr.split(' >= ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '>=');
        }
      }

      // Handle <= comparison (before < to avoid false match)
      if (expr.contains(' <= ')) {
        final parts = expr.split(' <= ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '<=');
        }
      }

      // Handle > comparison
      if (expr.contains(' > ')) {
        final parts = expr.split(' > ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '>');
        }
      }

      // Handle < comparison
      if (expr.contains(' < ')) {
        final parts = expr.split(' < ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = _fieldValue(formData, fieldName);
          return _compareValues(actualValue, expectedValue, '<');
        }
      }

      // Default: check if field exists and is truthy
      final fieldName = _extractFieldName(expr);
      final value = formData[fieldName];
      return value != null && value != '' && value != 0 && value != false;
    } catch (e, st) {
      // Fall back to the caller's declared safe answer. `true` suits
      // `depends_on` (show the field rather than hide data), but it is actively
      // harmful for `mandatory_depends_on`, where it makes an unparseable
      // expression block the save with no way for the user to satisfy it — see
      // [onError].
      debugPrint(
        'DependsOnEvaluator.evaluate failed for "$expression" — $e\n$st',
      );
      return onError;
    }
  }

  /// Reads a field for comparison, defaulting a MISSING `docstatus` to 0.
  ///
  /// In Frappe a document always has a `docstatus` — 0 while it is a draft — so
  /// desk expressions like `eval:doc.docstatus === 0` are true on a new doc.
  /// Form data assembled client-side does not always carry the key, and reading
  /// it as null made those expressions false, mis-gating every draft-only
  /// visibility / mandatory / read-only rule.
  static dynamic _fieldValue(Map<String, dynamic> formData, String fieldName) =>
      formData[fieldName] ?? (fieldName == 'docstatus' ? 0 : null);

  static String _extractFieldName(String expr) {
    // Remove doc. prefix if present
    expr = expr.trim();
    // Strip a trailing statement terminator — mirrors _extractValue below.
    // Frappe depends_on expressions are sometimes authored as `eval:doc.x;`
    // with a trailing semicolon. A Frappe fieldname can never contain `;`, so
    // this cannot mis-fire. Without it, the bare-truthy fallback looked up a
    // key like `x;` (or, via the leading-`!` branch, `district;`), never
    // found it in form data, and treated the field as permanently falsy.
    expr = expr.replaceAll(RegExp(r';\s*$'), '').trim();
    if (expr.startsWith('doc.')) {
      expr = expr.substring(4).trim();
    }
    return expr;
  }

  /// An expression that is NOTHING but one `doc.<fieldname>` reference, with
  /// an optional trailing statement terminator. The fieldname shape matches
  /// the reference regex in [extractEvalDocField]'s fallback, so both paths
  /// agree on what a fieldname may contain.
  static final RegExp _bareDocFieldRef = RegExp(
    r'^doc\.([A-Za-z_][A-Za-z0-9_]*)\s*;?\s*$',
  );

  /// Extract `doc.fieldname` from an eval expression like `eval:doc.x` or `eval: doc.x`.
  /// Returns the field name, or null if the value is not an eval:doc expression.
  static String? extractEvalDocField(String value) {
    String expr = value.trim();
    if (value.startsWith('eval:')) {
      expr = value.substring(5).trimLeft();
    }
    // Fast path ONLY when the whole expression is a bare `doc.<fieldname>`
    // reference (optional trailing `;`). The gate anchors on the FIELDNAME
    // SHAPE, and that is what makes it correct.
    //
    // The previous gate compared the expression against `_extractFieldName`'s
    // output — but that helper returns whatever remains after stripping a
    // leading `doc.`, with no check that the remainder is a legal fieldname.
    // For `doc.a && doc.b` it returns `a && doc.b`, which reassembles to
    // exactly `doc.a && doc.b`, so the equality held and the fast path handed
    // back `a && doc.b` AS A FIELDNAME. No such field exists, so the caller's
    // dependency lookup found nothing and the link picker silently stopped
    // filtering — the failure mode looks like "no filter", not like an error.
    final bare = _bareDocFieldRef.firstMatch(expr);
    if (bare != null) return bare.group(1);
    // The whole expression isn't a bare `doc.field` reference (e.g. it's
    // wrapped in a JS call like `(doc.x||'').replace(/.../, '')`). Fall back
    // to finding the first `doc.<field>` reference anywhere in the string so
    // dependent-field detection (used for the link field's "select X first"
    // UX) still works for these more complex link_filters expressions.
    final match = RegExp(r'doc\.([A-Za-z_][A-Za-z0-9_]*)').firstMatch(expr);
    return match?.group(1);
  }

  static dynamic _extractValue(String expr) {
    expr = expr.trim();
    // Strip a trailing statement terminator — Frappe depends_on expressions
    // are sometimes authored as `eval:doc.x == 1;` with a trailing semicolon,
    // which otherwise breaks the numeric-literal regexes below.
    if (expr.endsWith(';')) {
      expr = expr.substring(0, expr.length - 1).trim();
    }
    // Remove quotes if present
    if ((expr.startsWith('"') && expr.endsWith('"')) ||
        (expr.startsWith("'") && expr.endsWith("'"))) {
      expr = expr.substring(1, expr.length - 1);
    }
    // Try to parse as number
    if (RegExp(r'^-?\d+$').hasMatch(expr)) {
      return int.tryParse(expr);
    }
    if (RegExp(r'^-?\d+\.\d+$').hasMatch(expr)) {
      return double.tryParse(expr);
    }
    return expr;
  }

  /// Split [expr] by [delimiter], but only at top level — i.e. not inside
  /// `[...]` array literals, `(...)` grouped subexpressions, or quoted
  /// strings. Without paren awareness, a Frappe expression like
  /// `(A && B) || (C && D)` would split on the inner `&&`s first and produce
  /// fragments with unmatched parens; without quote awareness, a literal
  /// like `"A && B"` would be torn apart mid-string.
  static List<String> _splitOutsideBrackets(String expr, String delimiter) {
    final parts = <String>[];
    int bracketDepth = 0;
    int parenDepth = 0;
    int lastSplit = 0;
    String? quote;

    for (int i = 0; i < expr.length; i++) {
      final ch = expr[i];
      if (quote != null) {
        if (ch == quote) quote = null;
      } else if (ch == '"' || ch == "'") {
        quote = ch;
      } else if (ch == '[') {
        bracketDepth++;
      } else if (ch == ']') {
        bracketDepth--;
      } else if (ch == '(') {
        parenDepth++;
      } else if (ch == ')') {
        parenDepth--;
      } else if (bracketDepth == 0 &&
          parenDepth == 0 &&
          i + delimiter.length <= expr.length &&
          expr.substring(i, i + delimiter.length) == delimiter) {
        parts.add(expr.substring(lastSplit, i));
        lastSplit = i + delimiter.length;
        i += delimiter.length - 1;
      }
    }
    parts.add(expr.substring(lastSplit));
    return parts;
  }

  /// Strip balanced outermost parens — but only when they wrap the whole
  /// expression (the matching `)` is at the end). `(A) || (B)` keeps both
  /// pairs because neither pair spans the whole string. Repeats so
  /// `((A))` flattens fully.
  /// Matches the `.some(<param> => <body>)` envelope over a child table.
  ///
  /// Accepts both the guarded form `(doc.tbl || []).some(...)` and the bare
  /// `doc.tbl.some(...)`. Groups: 1 = table fieldname, 2 = arrow parameter,
  /// 3 = arrow body.
  /// The trailing `;?` matters: Frappe authors routinely end a `depends_on`
  /// with a statement terminator.
  static final RegExp _someEnvelope = RegExp(
    r'^\(?\s*doc\.(\w+)\s*(?:\|\|\s*\[\s*\]\s*)?\)?\s*\.some\(\s*(\w+)\s*=>\s*(.+)\)\s*;?\s*$',
  );

  /// `row.field <op> value` — the strict-equality body.
  static final RegExp _someCompareBody = RegExp(
    r'^(\w+)\.(\w+)\s*(===|!==|==|!=)\s*(.+)$',
  );

  /// `(row.field || '').toLowerCase().includes(value)` and its simpler
  /// variants — the substring-match body. `.toLowerCase()` and the `|| ''`
  /// guard are both optional.
  static final RegExp _someIncludesBody = RegExp(
    r"""^\(?\s*(\w+)\.(\w+)\s*(?:\|\|\s*(?:''|"")\s*)?\)?\s*(\.toLowerCase\(\))?\s*\.includes\(\s*(.+?)\s*\)$""",
  );

  /// Evaluates a child-table `.some(...)` predicate.
  ///
  /// Returns `null` when [expr] is not a `.some(...)` shape at all, so the
  /// caller can fall through to the other branches. A recognised shape over a
  /// missing or empty table is a real answer — `false` — not a fall-through.
  static bool? _evaluateChildTableSome(
    String expr,
    Map<String, dynamic> formData,
  ) {
    final envelope = _someEnvelope.firstMatch(expr);
    if (envelope == null) return null;

    final tableField = envelope.group(1)!;
    final param = envelope.group(2)!;
    final body = envelope.group(3)!.trim();

    // Resolve the predicate first, so an unrecognised body falls through to the
    // legacy branches rather than silently answering false.
    bool Function(Map<dynamic, dynamic> row)? predicate;

    final compare = _someCompareBody.firstMatch(body);
    if (compare != null && compare.group(1) == param) {
      final rowField = compare.group(2)!;
      final op = compare.group(3)!;
      final expected = _extractValue(compare.group(4)!);
      predicate = (row) {
        final actual = row[rowField];
        final equal = _compareValues(actual, expected, '==');
        return op.startsWith('!') ? !equal : equal;
      };
    } else {
      final includes = _someIncludesBody.firstMatch(body);
      if (includes != null && includes.group(1) == param) {
        final rowField = includes.group(2)!;
        final lowered = includes.group(3) != null;
        final needleRaw = _extractValue(includes.group(4)!)?.toString() ?? '';
        final needle = lowered ? needleRaw.toLowerCase() : needleRaw;
        predicate = (row) {
          var haystack = row[rowField]?.toString() ?? '';
          if (lowered) haystack = haystack.toLowerCase();
          return needle.isNotEmpty && haystack.contains(needle);
        };
      }
    }

    if (predicate == null) return null;

    final rows = formData[tableField];
    if (rows is! List) return false;
    for (final row in rows) {
      if (row is Map && predicate(row)) return true;
    }
    return false;
  }

  static String _stripOuterParens(String expr) {
    String s = expr.trim();
    while (s.length >= 2 && s.startsWith('(') && s.endsWith(')')) {
      int depth = 0;
      bool wholeExpr = false;
      for (int i = 0; i < s.length; i++) {
        if (s[i] == '(') {
          depth++;
        } else if (s[i] == ')') {
          depth--;
          if (depth == 0) {
            wholeExpr = (i == s.length - 1);
            break;
          }
        }
      }
      if (!wholeExpr) break;
      s = s.substring(1, s.length - 1).trim();
    }
    return s;
  }

  /// Parse comma-separated quoted values from inside array brackets.
  static List<String> _parseArrayValues(String arrayContent) {
    final values = <String>[];
    final regex = RegExp(r"""['"]([^'"]*?)['"]""");
    for (final match in regex.allMatches(arrayContent)) {
      values.add(match.group(1)!);
    }
    return values;
  }

  static bool _compareValues(
    dynamic actual,
    dynamic expected,
    String operator,
  ) {
    switch (operator) {
      case '==':
        if (actual == expected) return true;
        // Fallback: compare as strings to handle type mismatches
        // (e.g. int 1 vs String "1" from Frappe form data)
        return actual?.toString() == expected?.toString();
      case '!=':
        if (actual == expected) return false;
        return actual?.toString() != expected?.toString();
      case '>':
      case '<':
      case '>=':
      case '<=':
        // Relational comparisons need numeric operands. Frappe form data often
        // carries numeric field values as strings (e.g. a Float field read back
        // as "10.0"), and JS `depends_on` coerces those before comparing. Mirror
        // that by parsing both sides; if either isn't numeric, the comparison is
        // undefined → false (same as the old num-only guard for non-numbers).
        final a = _toNum(actual);
        final b = _toNum(expected);
        if (a == null || b == null) return false;
        switch (operator) {
          case '>':
            return a > b;
          case '<':
            return a < b;
          case '>=':
            return a >= b;
          case '<=':
            return a <= b;
        }
        return false;
      default:
        return false;
    }
  }

  /// Coerce a value to [num] for relational comparisons: passes numbers
  /// through, parses numeric strings (trimmed), and returns null for anything
  /// non-numeric (null, bool, non-numeric text) so the caller treats it as an
  /// unsatisfiable comparison rather than throwing.
  static num? _toNum(dynamic v) {
    if (v is num) return v;
    if (v is String) return num.tryParse(v.trim());
    return null;
  }
}
