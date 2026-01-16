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
