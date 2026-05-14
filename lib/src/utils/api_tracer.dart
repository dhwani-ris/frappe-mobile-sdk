// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Debug-mode API call tracer. Only logs when kDebugMode is true.

import 'package:flutter/foundation.dart';

/// Single utility for tracing API calls in debug mode.
/// Call [traceRequest] before and [traceResponse] after each HTTP call.
class ApiTracer {
  static const String _tag = '[Frappe API]';

  /// Caps a body / Map / List string at 500 chars for log readability.
  /// Non-collection bodies pass through as `toString()`. Shared by
  /// [traceRequest] and [traceResponse] so a threshold change applies to
  /// both at once.
  static String _preview(dynamic body) {
    if (body is Map || body is List) {
      final s = body.toString();
      return s.length > 500 ? '${s.substring(0, 500)}...' : s;
    }
    return body.toString();
  }

  /// Log request (method, url, body). No-op in release.
  static void traceRequest({
    required String method,
    required String url,
    Map<String, dynamic>? queryParams,
    dynamic body,
  }) {
    if (!kDebugMode) return;
    final buffer = StringBuffer();
    buffer.writeln('$_tag REQUEST $method $url');
    if (queryParams != null && queryParams.isNotEmpty) {
      buffer.writeln('  query: $queryParams');
    }
    if (body != null) {
      buffer.writeln('  body: ${_preview(body)}');
    }
    debugPrint(buffer.toString());
  }

  /// Log response (status, body or error). No-op in release.
  static void traceResponse({
    required int statusCode,
    required String url,
    dynamic body,
    Object? error,
  }) {
    if (!kDebugMode) return;
    final buffer = StringBuffer();
    buffer.writeln('$_tag RESPONSE $statusCode $url');
    if (error != null) {
      buffer.writeln('  error: $error');
    } else if (body != null) {
      buffer.writeln('  body: ${_preview(body)}');
    }
    debugPrint(buffer.toString());
  }
}
