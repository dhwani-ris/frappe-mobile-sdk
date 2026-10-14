// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// Debug-mode API call tracer. Only logs when kDebugMode is true.

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Single utility for tracing API calls in debug mode.
/// Call [traceRequest] before and [traceResponse] after each HTTP call.
///
/// Secrets never reach the log: values under [_secretKeys] are replaced with
/// [_mask] in URL query strings, query maps and bodies (Map, List, JSON
/// string, form-encoded string, or any other text) before anything is
/// printed or truncated. Keys match EXACTLY after [_normaliseKey] (so
/// `apiKey`, `Api-Secret` match, but `pincode`, `country_code` do not).
class ApiTracer {
  static const String _tag = '[Frappe API]';
  static const String _mask = '***';
  static const int _previewLimit = 500;

  /// Stored in [_normaliseKey] form.
  static const Set<String> _secretKeys = {
    'password',
    'pwd',
    'newpassword',
    'oldpassword',
    'accesstoken',
    'refreshtoken',
    'apisecret',
    'apikey',
    'token',
    'secret',
    'otp',
    'tmpid',
    'sid',
    'csrftoken',
    'xfrappecsrftoken',
    'authorization',
    'cookie',
    'clientsecret',
    'code',
    'codeverifier',
  };

  /// A `key:` or `key=` in free text; the lookbehind stops `pincode` being
  /// read as `code`.
  static final RegExp _textKey = RegExp(
    r'''(?<![\w-])(["']?)([A-Za-z][\w-]*)\1\s*[:=]\s*''',
  );
  static final RegExp _strictForm = RegExp(
    r'^[^=&\s]+=[^&\s]*(&[^=&\s]+=[^&\s]*)*$',
  );

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

  static String _normaliseKey(Object? key) =>
      key.toString().toLowerCase().replaceAll(RegExp('[_-]'), '');

  static bool _isSecretKey(Object? key) =>
      _secretKeys.contains(_normaliseKey(key));

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

  /// A string body is redacted structurally when it is JSON or strict
  /// form-encoded `k=v&k=v`; any other text (colon-style, truncated JSON,
  /// an HTML error page) goes through [_redactText].
  static String _redactString(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return jsonEncode(_redact(jsonDecode(text)));
      } on FormatException {
        // Not valid JSON (e.g. truncated); fall through.
      }
    }
    return _strictForm.hasMatch(text) ? _redactForm(text) : _redactText(text);
  }

  /// Masks the value after every secret `key:` / `key=` in free text: a
  /// quoted value up to its closing quote (or the end, if cut off), else up
  /// to the end of the line or the next `,;&}]`.
  static String _redactText(String text) {
    final out = StringBuffer();
    var cursor = 0;
    for (final m in _textKey.allMatches(text)) {
      if (m.start < cursor || !_isSecretKey(m.group(2))) continue;
      final valueStart = m.end;
      var valueEnd = valueStart;
      final quote = valueStart < text.length ? text[valueStart] : '';
      if (quote == '"' || quote == "'") {
        final close = text.indexOf(quote, valueStart + 1);
        valueEnd = close < 0 ? text.length : close + 1;
        out
          ..write(text.substring(cursor, valueStart))
          ..write(close < 0 ? '$quote$_mask' : '$quote$_mask$quote');
      } else {
        while (valueEnd < text.length &&
            !'\r\n,;&}]'.contains(text[valueEnd])) {
          valueEnd++;
        }
        out
          ..write(text.substring(cursor, valueStart))
          ..write(_mask);
      }
      cursor = valueEnd;
    }
    out.write(text.substring(cursor));
    return out.toString();
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
