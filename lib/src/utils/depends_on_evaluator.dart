// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/foundation.dart';

/// Evaluates Frappe depends_on expressions
class DependsOnEvaluator {
  /// Evaluate depends_on expression
  /// Supports: eval:doc.field == value, eval:doc.field != value, etc.
  static bool evaluate(String? expression, Map<String, dynamic> formData) {
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
        return andParts.every((part) => evaluate(part.trim(), formData));
      }

      // Handle || (OR) operator — same bracket-aware splitting
      final orParts = _splitOutsideBrackets(expr, ' || ');
      if (orParts.length > 1) {
        return orParts.any((part) => evaluate(part.trim(), formData));
      }

      // Handle [values].includes(doc.field) pattern
      final includesMatch = RegExp(
        r"^\[(.*)?\]\.includes\(doc\.(\w+)\)$",
      ).firstMatch(expr);
      if (includesMatch != null) {
        final arrayContent = includesMatch.group(1) ?? '';
        final fieldName = includesMatch.group(2)!;
        final values = _parseArrayValues(arrayContent);
        final actual = formData[fieldName];
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
          final actualValue = formData[fieldName];
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
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '!=');
        }
      }

      // Handle == comparison
      if (expr.contains(' == ')) {
        final parts = expr.split(' == ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '==');
        }
      }

      // Handle != comparison
      if (expr.contains(' != ')) {
        final parts = expr.split(' != ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '!=');
        }
      }

      // Handle >= comparison (before > to avoid false match)
      if (expr.contains(' >= ')) {
        final parts = expr.split(' >= ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '>=');
        }
      }

      // Handle <= comparison (before < to avoid false match)
      if (expr.contains(' <= ')) {
        final parts = expr.split(' <= ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '<=');
        }
      }

      // Handle > comparison
      if (expr.contains(' > ')) {
        final parts = expr.split(' > ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '>');
        }
      }

      // Handle < comparison
      if (expr.contains(' < ')) {
        final parts = expr.split(' < ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '<');
        }
      }

      // Default: check if field exists and is truthy
      final fieldName = _extractFieldName(expr);
      final value = formData[fieldName];
      return value != null && value != '' && value != 0 && value != false;
    } catch (e, st) {
      // If evaluation fails, default to true (show field)
      debugPrint(
        'DependsOnEvaluator.evaluate failed for "$expression" — $e\n$st',
      );
      return true;
    }
  }

  static String _extractFieldName(String expr) {
    // Remove doc. prefix if present
    expr = expr.trim();
    if (expr.startsWith('doc.')) {
      expr = expr.substring(4).trim();
    }
    return expr;
  }

  /// Extract `doc.fieldname` from an eval expression like `eval:doc.x` or `eval: doc.x`.
  /// Returns the field name, or null if the value is not an eval:doc expression.
  static String? extractEvalDocField(String value) {
    String expr = value.trim();
    if (value.startsWith('eval:')) {
      expr = value.substring(5).trimLeft();
    }
    String fieldName = _extractFieldName(expr);
    return expr == fieldName ? null : fieldName;
  }

  static dynamic _extractValue(String expr) {
    expr = expr.trim();
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
  /// `[...]` array literals or `(...)` grouped subexpressions. Without paren
  /// awareness, a Frappe expression like `(A && B) || (C && D)` would split
  /// on the inner `&&`s first and produce fragments with unmatched parens.
  static List<String> _splitOutsideBrackets(String expr, String delimiter) {
    final parts = <String>[];
    int bracketDepth = 0;
    int parenDepth = 0;
    int lastSplit = 0;

    for (int i = 0; i < expr.length; i++) {
      final ch = expr[i];
      if (ch == '[') {
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
        if (actual is num && expected is num) {
          return actual > expected;
        }
        return false;
      case '<':
        if (actual is num && expected is num) {
          return actual < expected;
        }
        return false;
      case '>=':
        if (actual is num && expected is num) {
          return actual >= expected;
        }
        return false;
      case '<=':
        if (actual is num && expected is num) {
          return actual <= expected;
        }
        return false;
      default:
        return false;
    }
  }
}
