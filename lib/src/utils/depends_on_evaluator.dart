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

      // Handle >= comparison
      if (expr.contains(' >= ')) {
        final parts = expr.split(' >= ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '>=');
        }
      }

      // Handle <= comparison
      if (expr.contains(' <= ')) {
        final parts = expr.split(' <= ');
        if (parts.length == 2) {
          final fieldName = _extractFieldName(parts[0]);
          final expectedValue = _extractValue(parts[1]);
          final actualValue = formData[fieldName];
          return _compareValues(actualValue, expectedValue, '<=');
        }
      }

      // Handle && (AND) operator
      if (expr.contains(' && ')) {
        final parts = expr.split(' && ');
        return parts.every((part) => evaluate(part.trim(), formData));
      }

      // Handle || (OR) operator
      if (expr.contains(' || ')) {
        final parts = expr.split(' || ');
        return parts.any((part) => evaluate(part.trim(), formData));
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
