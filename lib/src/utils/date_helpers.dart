import 'package:flutter/material.dart' show TimeOfDay;

/// Coerces a dynamic value into a [DateTime] or null.
/// - `null` → null
/// - `DateTime` → returned as-is
/// - `String` → parsed via [DateTime.tryParse]; null on parse failure
/// - any other type → null
///
/// Shared by the date and datetime field widgets and by the form builder's
/// patched-value normalizer so the coercion logic lives in one place.
DateTime? parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Coerces a dynamic value into a "time of day" expressed as a [DateTime]
/// on the current calendar day. Accepts the same shapes as [parseDateTime]
/// plus `TimeOfDay` (returns today @ hh:mm) and a manual `HH:MM[:SS]`
/// string split that [DateTime.tryParse] would reject (because Frappe
/// persists Time fields as bare `HH:MM:SS` without a date prefix).
DateTime? parseTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is TimeOfDay) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, value.hour, value.minute);
  }
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed;
    // Fall back to manual `HH:MM[:SS]` split.
    final parts = value.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final s = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
      if (h != null && m != null) {
        final now = DateTime.now();
        return DateTime(now.year, now.month, now.day, h, m, s);
      }
    }
  }
  return null;
}

/// Formats a duration expressed in seconds as `HH:MM:SS` (when hours > 0)
/// or `MM:SS`. Each component is zero-padded to two digits. Shared by the
/// Duration field widget and the form builder's patched-value formatter.
String formatDurationSeconds(int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${secs.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:'
      '${secs.toString().padLeft(2, '0')}';
}
