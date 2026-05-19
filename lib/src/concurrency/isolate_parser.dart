import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Parses JSON page bodies for the pull engine. Small payloads stay on the
/// main isolate (avoids the cost of spinning up an isolate); larger ones
/// dispatch to `compute()` so JSON parsing doesn't block UI frames.
class IsolateParser {
  /// Threshold under which parsing happens inline. 8 KiB is a conservative
  /// boundary — payloads above this typically take long enough that the
  /// isolate hop is cheaper than the parse-on-UI hit.
  static const int _inlineThresholdBytes = 8 * 1024;

  /// Parses a Frappe list response of the shape `{"data":[...]}` into a
  /// `List<Map<String,dynamic>>`.
  static Future<List<Map<String, dynamic>>> parsePageData(String body) async {
    if (body.length < _inlineThresholdBytes) {
      return _parse(body);
    }
    return compute(_parse, body);
  }

  static List<Map<String, dynamic>> _parse(String body) {
    final obj = jsonDecode(body);
    if (obj is! Map || !obj.containsKey('data')) {
      throw const FormatException('Expected {"data": [...]}');
    }
    final list = (obj['data'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return list;
  }
}
