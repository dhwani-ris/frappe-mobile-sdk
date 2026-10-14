// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Debug-mode API call tracer. Only logs when kDebugMode is true.

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Single utility for tracing API calls in debug mode.
/// Call [traceRequest] before and [traceResponse] after each HTTP call.
///
/// Secrets never reach the log: values under [_secretKeys] (matched
/// case-insensitively, at any depth) are replaced with [_mask] in URL query
/// strings, query maps and bodies (Map, List, JSON string or form-encoded
/// string) before anything is printed or truncated.
class ApiTracer {
  static const String _tag = '[Frappe API]';
  static const String _mask = '***';
  static const int _previewLimit = 500;
  static const Set<String> _secretKeys = {
    'password',
    'pwd',
    'new_password',
    'old_password',
    'access_token',
    'refresh_token',
    'api_secret',
    'api_key',
    'token',
    'secret',
  };

  /// Log request (method, url, body). No-op in release.
  static void traceRequest({
    required String method,
    required String url,
    Map<String, dynamic>? queryParams,
    dynamic body,
  }) {
    if (!kDebugMode) return;
    final buffer = StringBuffer();
    buffer.writeln('$_tag REQUEST $method ${_redactUrl(url)}');
    if (queryParams != null && queryParams.isNotEmpty) {
      buffer.writeln('  query: ${_redact(queryParams)}');
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
    buffer.writeln('$_tag RESPONSE $statusCode ${_redactUrl(url)}');
    if (error != null) {
      buffer.writeln('  error: $error');
    } else if (body != null) {
      buffer.writeln('  body: ${_preview(body)}');
    }
    debugPrint(buffer.toString());
  }

  /// Redacted body text; Map/List bodies are cut to [_previewLimit] chars
  /// AFTER redaction so a cut can never expose part of a secret.
  static String _preview(dynamic body) {
    final text = _redact(body).toString();
    if ((body is Map || body is List) && text.length > _previewLimit) {
      return '${text.substring(0, _previewLimit)}...';
    }
    return text;
  }

  static bool _isSecretKey(Object? key) =>
      _secretKeys.contains(key.toString().toLowerCase());

  static dynamic _redact(dynamic value) {
    if (value is Map) {
      return value.map(
        (k, v) => MapEntry(k, _isSecretKey(k) ? _mask : _redact(v)),
      );
    }
    if (value is List) return value.map(_redact).toList();
    if (value is String) return _redactString(value);
    return value;
  }

  /// A string body is either JSON (redacted structurally) or treated as
  /// form-encoded `k=v&k=v`; text with no `=` passes through untouched.
  static String _redactString(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return jsonEncode(_redact(jsonDecode(text)));
      } on FormatException {
        // Not JSON after all; fall through to the form-encoded pass.
      }
    }
    return text.contains('=') ? _redactForm(text) : text;
  }

  static String _redactForm(String form) {
    return form
        .split('&')
        .map((pair) {
          final eq = pair.indexOf('=');
          if (eq < 0) return pair;
          final rawKey = pair.substring(0, eq);
          String key;
          try {
            key = Uri.decodeQueryComponent(rawKey);
          } on ArgumentError {
            key = rawKey;
          } on FormatException {
            key = rawKey;
          }
          return _isSecretKey(key) ? '$rawKey=$_mask' : pair;
        })
        .join('&');
  }

  static String _redactUrl(String url) {
    final q = url.indexOf('?');
    if (q < 0) return url;
    final hash = url.indexOf('#', q);
    final end = hash < 0 ? url.length : hash;
    return '${url.substring(0, q + 1)}'
        '${_redactForm(url.substring(q + 1, end))}'
        '${url.substring(end)}';
  }
}
