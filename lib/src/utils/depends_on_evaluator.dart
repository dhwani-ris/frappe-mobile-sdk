// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

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
    } catch (e) {
      // If evaluation fails, default to true (show field)
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

  /// Split expression by delimiter, but only when not inside [...] brackets.
  static List<String> _splitOutsideBrackets(String expr, String delimiter) {
    final parts = <String>[];
    int bracketDepth = 0;
    int lastSplit = 0;

    for (int i = 0; i < expr.length; i++) {
      if (expr[i] == '[') {
        bracketDepth++;
      } else if (expr[i] == ']') {
        bracketDepth--;
      } else if (bracketDepth == 0 &&
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
        return actual == expected;
      case '!=':
        return actual != expected;
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
