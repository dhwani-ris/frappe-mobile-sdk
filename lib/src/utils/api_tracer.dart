// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Debug-mode API call tracer. Only logs when kDebugMode is true.

import 'package:flutter/foundation.dart';

/// Single utility for tracing API calls in debug mode.
/// Call [traceRequest] before and [traceResponse] after each HTTP call.
class ApiTracer {
  static const String _tag = '[Frappe API]';

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
      final preview = body is Map || body is List
          ? body.toString().length > 500
                ? '${body.toString().substring(0, 500)}...'
                : body.toString()
          : body.toString();
      buffer.writeln('  body: $preview');
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
      final preview = body is Map || body is List
          ? body.toString().length > 500
                ? '${body.toString().substring(0, 500)}...'
                : body.toString()
          : body.toString();
      buffer.writeln('  body: $preview');
    }
    debugPrint(buffer.toString());
  }
}
