// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Debug-mode API call tracer. Only logs when kDebugMode is true.

import 'package:flutter/foundation.dart';

/// Single utility for tracing API calls in debug mode.
/// Call [traceRequest] before and [traceResponse] after each HTTP call.
class ApiTracer {
  static const String _tag = '[Frappe API]';

  /// Field names whose values are credentials and must never reach a log:
  /// passwords, OTPs, access/refresh tokens, API and client secrets, PKCE
  /// verifiers. Matched case-insensitively against each key of a Map body or
  /// query, at any depth.
  static final RegExp _sensitiveKey = RegExp(
    r'password|passwd|secret|token|otp|code_verifier|authorization|^pwd$|^sid$',
    caseSensitive: false,
  );

  static const String _redacted = 'REDACTED';

  /// Returns [value] with the value of every credential-named key replaced
  /// by `REDACTED`, so a debug trace of a login or refresh call does not
  /// print the password, OTP or token it carries.
  @visibleForTesting
  static dynamic redact(dynamic value) {
    if (value is Map) {
      return value.map(
        (k, v) => MapEntry(
          k,
          _sensitiveKey.hasMatch(k.toString()) ? _redacted : redact(v),
        ),
      );
    }
    if (value is List) return value.map(redact).toList();
    return value;
  }

  /// [url] with the value of every credential-named query parameter
  /// replaced, for the same reason as [redact].
  @visibleForTesting
  static String redactUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasQuery) return url;
    if (!uri.queryParametersAll.keys.any(_sensitiveKey.hasMatch)) return url;
    return uri
        .replace(
          queryParameters: uri.queryParametersAll.map(
            (k, v) => MapEntry(k, _sensitiveKey.hasMatch(k) ? _redacted : v),
          ),
        )
        .toString();
  }

  /// Caps a body / Map / List string at 500 chars for log readability.
  /// Non-collection bodies pass through as `toString()`. Shared by
  /// [traceRequest] and [traceResponse] so a threshold change applies to
  /// both at once. Credential-named keys are redacted first.
  static String _preview(dynamic body) {
    if (body is Map || body is List) {
      final s = redact(body).toString();
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
    buffer.writeln('$_tag REQUEST $method ${redactUrl(url)}');
    if (queryParams != null && queryParams.isNotEmpty) {
      buffer.writeln('  query: ${redact(queryParams)}');
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
    buffer.writeln('$_tag RESPONSE $statusCode ${redactUrl(url)}');
    if (error != null) {
      buffer.writeln('  error: $error');
    } else if (body != null) {
      buffer.writeln('  body: ${_preview(body)}');
    }
    debugPrint(buffer.toString());
  }
}
