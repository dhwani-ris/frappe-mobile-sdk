// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

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
String extractErrorMessage(dynamic body) {
  if (body is! Map) return body.toString();

  if (body.containsKey('exception')) {
    return body['exception'].toString();
  }
  if (body.containsKey('message')) {
    return body['message'].toString();
  }
  if (body.containsKey('_server_messages')) {
    try {
      return body['_server_messages'].toString();
    } catch (_) {}
  }
  return 'Unknown Error';
}

/// Convert Frappe API error (traceback / exception string) to a short user-friendly message.
/// e.g. "frappe.exceptions.ValidationError: Farmer Name is required\nErrors: ..." -> "Farmer Name is required"
String toUserFriendlyMessage(dynamic error) {
  final raw = error is String ? error : error.toString();
  if (raw.isEmpty) return 'Something went wrong. Please try again.';

  final patterns = [
    RegExp(r'ValidationError:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)', caseSensitive: false, dotAll: true),
    RegExp(r'frappe\.exceptions\.ValidationError:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)', caseSensitive: false, dotAll: true),
    RegExp(r'ValidationException:\s*(.+?)(?:\s*Errors:|\s*Traceback|\n|$)', caseSensitive: false, dotAll: true),
    RegExp(r'(.+?\s+is\s+required\.?)', caseSensitive: false, dotAll: true),
    RegExp(r'(.+?)(?:\s*Traceback\s*\(most recent)', caseSensitive: false, dotAll: true),
    RegExp(r'^([^\n\r]+)', dotAll: false),
  ];

  for (final re in patterns) {
    final m = re.firstMatch(raw);
    if (m != null) {
      final msg = m.group(1)?.trim() ?? '';
      if (msg.isNotEmpty && msg.length < 200 && !msg.contains('Traceback')) {
        if (msg.endsWith('.')) return msg;
        if (!msg.endsWith('!') && !msg.endsWith('?')) return '$msg.';
        return msg;
      }
    }
  }

  if (raw.length > 250) {
    final firstLine = raw.split(RegExp(r'\n|\r')).first.trim();
    if (firstLine.length < 200) return firstLine;
    return '${raw.substring(0, 120).trim()}…';
  }
  return raw;
}
