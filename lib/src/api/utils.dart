// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';

Map<String, String> parseSetCookie(String setCookieValue) {
  final cookies = <String, String>{};
  final parts = setCookieValue.split(',');
  for (var part in parts) {
    final cookiePart = part.split(';').first.trim();
    final equalsIndex = cookiePart.indexOf('=');
    if (equalsIndex > 0) {
      final name = cookiePart.substring(0, equalsIndex);
      final value = cookiePart.substring(equalsIndex + 1);
      cookies[name] = value;
    }
  }
  return cookies;
}

/// Extract raw error string from API body (may contain traceback).
/// Strips HTML tags for readability.
String extractErrorMessage(dynamic body) {
  if (body is! Map) return body.toString();

  String? raw;

  // Try _server_messages first (cleaner)
  if (body.containsKey('_server_messages')) {
    try {
      final serverMsg = _extractServerMessage(body);
      if (serverMsg != null && serverMsg.isNotEmpty) {
        raw = serverMsg;
      }
    } catch (_) {}
  }

  if (raw == null && body.containsKey('exception')) {
    raw = body['exception'].toString();
    // Parse exception to extract meaningful message (similar to toUserFriendlyMessage)
    raw = _extractExceptionMessage(raw);
  }
  if (raw == null && body.containsKey('message')) {
    raw = body['message'].toString();
  }

  if (raw == null) return 'Unknown Error';

  // Strip HTML tags for readability
  return _stripHtmlTags(raw);
}

/// Strip HTML tags from text, keeping only the text content.
/// e.g. "<a href='...'>FRM-0000000016</a>" -> "FRM-0000000016"
String _stripHtmlTags(String html) {
  return html
      .replaceAll(RegExp(r'<a[^>]*>'), '')
      .replaceAll(RegExp(r'</a>'), '')
      .replaceAll(RegExp(r'<[^>]*>'), '')
      .replaceAll(RegExp(r'&nbsp;'), ' ')
      .replaceAll(RegExp(r'&amp;'), '&')
      .replaceAll(RegExp(r'&lt;'), '<')
      .replaceAll(RegExp(r'&gt;'), '>')
      .replaceAll(RegExp(r'&quot;'), '"')
      .replaceAll(RegExp(r'&#39;'), "'")
      .trim();
}

/// Extract exception message from _server_messages JSON if present.
String? _extractServerMessage(dynamic body) {
  if (body is Map && body.containsKey('_server_messages')) {
    try {
      final serverMsgs = body['_server_messages'];
      if (serverMsgs is String) {
        final decoded = jsonDecode(serverMsgs) as List;
        if (decoded.isNotEmpty && decoded.first is Map) {
          final msg = decoded.first as Map;
          return msg['message']?.toString();
        }
      }
    } catch (_) {}
  }
  return null;
}

/// Extract meaningful message from exception string (removes traceback).
String _extractExceptionMessage(String exception) {
  // Try to extract just the error message, removing traceback
  final patterns = [
    RegExp(
      r'ValidationError:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(
      r'frappe\.exceptions\.ValidationError:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(
      r'(.+?)(?:\s*Traceback\s*\(most recent)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(r'^([^\n\r]+)', dotAll: false),
  ];

  for (final re in patterns) {
    final m = re.firstMatch(exception);
    if (m != null) {
      final msg = m.group(1)?.trim() ?? '';
      if (msg.isNotEmpty && !msg.contains('Traceback')) {
        return msg;
      }
    }
  }

  return exception;
}

/// Convert Frappe API error (traceback / exception string) to a short user-friendly message.
/// e.g. "frappe.exceptions.ValidationError: Farmer Name is required\nErrors: ..." -> "Farmer Name is required"
/// Also strips HTML tags from messages.
String toUserFriendlyMessage(dynamic error) {
  String raw = error is String ? error : error.toString();
  if (raw.isEmpty) return 'Something went wrong. Please try again.';

  // Try to extract from _server_messages first (cleaner message)
  if (error is Map) {
    final serverMsg = _extractServerMessage(error);
    if (serverMsg != null && serverMsg.isNotEmpty) {
      raw = serverMsg;
    } else if (error.containsKey('exception')) {
      raw = error['exception'].toString();
    }
  }

  // Strip HTML tags
  raw = _stripHtmlTags(raw);

  final patterns = [
    RegExp(
      r'LinkExistsError:\s*(.+?)(?:\s*Traceback|\n|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(
      r'frappe\.exceptions\.LinkExistsError:\s*(.+?)(?:\s*Traceback|\n|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(
      r'ValidationError:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(
      r'frappe\.exceptions\.ValidationError:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(
      r'ValidationException:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(r'(.+?\s+is\s+required\.?)', caseSensitive: false, dotAll: true),
    RegExp(
      r'(.+?)(?:\s*Traceback\s*\(most recent)',
      caseSensitive: false,
      dotAll: true,
    ),
    RegExp(r'^([^\n\r]+)', dotAll: false),
  ];

  for (final re in patterns) {
    final m = re.firstMatch(raw);
    if (m != null) {
      var msg = m.group(1)?.trim() ?? '';
      msg = _stripHtmlTags(msg);
      if (msg.isNotEmpty && msg.length < 200 && !msg.contains('Traceback')) {
        if (msg.endsWith('.')) return msg;
        if (!msg.endsWith('!') && !msg.endsWith('?')) return '$msg.';
        return msg;
      }
    }
  }

  if (raw.length > 250) {
    final firstLine = raw.split(RegExp(r'\n|\r')).first.trim();
    final cleaned = _stripHtmlTags(firstLine);
    if (cleaned.length < 200) return cleaned;
    return '${cleaned.substring(0, 120).trim()}…';
  }
  return raw;
}
