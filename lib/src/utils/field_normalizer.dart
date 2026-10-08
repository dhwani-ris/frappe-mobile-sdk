import 'package:flutter/material.dart';

import '../constants/field_types.dart';
import '../models/doc_field.dart';
import 'date_helpers.dart';

/// Coerces a raw value into the canonical in-form representation for a given
/// [DocField], dispatched on its `fieldtype`.
///
/// Pure logic with no widget state — extracted from `FrappeFormBuilder` so the
/// per-fieldtype normalization rules can be unit-tested directly instead of
/// only through the widget.
class FieldNormalizer {
  const FieldNormalizer._();

  /// Normalize [value] to the shape the form expects for [field].
  static dynamic normalize(DocField field, dynamic value) {
    switch (field.fieldtype) {
      case FieldTypes.date:
      case FieldTypes.datetime:
        if (value == null || value == '') return null;
        if (value is DateTime) return value;
        if (value is String) return DateTime.tryParse(value);
        return null;

      case FieldTypes.time:
        if (value == null || value == '') return null;
        if (value is DateTime) return value;
        if (value is TimeOfDay) {
          return DateTime(2000, 1, 1, value.hour, value.minute);
        }
        if (value is String) {
          final parts = value.split(':');
          if (parts.length >= 2) {
            final hour = int.tryParse(parts[0]);
            final minute = int.tryParse(parts[1]);
            if (hour != null && minute != null) {
              return DateTime(2000, 1, 1, hour, minute);
            }
          }
        }
        return null;

      case FieldTypes.check:
        if (value is bool) return value;
        if (value is int) return value == 1;
        if (value is String) {
          final normalized = value.trim().toLowerCase();
          return normalized == '1' || normalized == 'true';
        }
        return false;

      case FieldTypes.rating:
        // A Rating is a 0..1 fraction (see RatingField), so it must stay a
        // double: parsing it as an int turned every stored fraction (0.6) into
        // null, and the form's post-frame patch then cleared the stars.
        if (value == null || value == '') return null;
        if (value is num) return value.toDouble();
        return double.tryParse(value.toString());

      case FieldTypes.select:
        if (field.options == null || field.options!.trim().isEmpty) {
          return value?.toString() ?? '';
        }
        if (field.allowMultiple) {
          return _normalizeMultiSelect(value);
        }
        final stringValue = value?.toString();
        if (stringValue == null || stringValue.isEmpty) return null;
        // Coerce a value that is no longer one of the field's options to null.
        // A removed/renamed option (or a stale saved value on an old record)
        // would otherwise reach FormBuilderDropdown, which asserts on an
        // out-of-options value. SelectField surfaces a hint when this drops a
        // non-empty value, so the coercion is visible rather than silent.
        final opts = field.options!
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        return opts.contains(stringValue) ? stringValue : null;

      case FieldTypes.link:
      case FieldTypes.data:
      case FieldTypes.text:
      case FieldTypes.longText:
      case FieldTypes.smallText:
      case FieldTypes.password:
      case FieldTypes.phone:
      case FieldTypes.attach:
      case FieldTypes.attachImage:
      case FieldTypes.image:
      case FieldTypes.readOnly:
        return value?.toString() ?? '';

      case FieldTypes.int:
      case FieldTypes.float:
      case FieldTypes.currency:
      case FieldTypes.percent:
        return value?.toString() ?? '';

      case FieldTypes.duration:
        if (value == null || value == '') return '';
        if (value is int) return formatDurationSeconds(value);
        return value.toString();

      case 'Table':
        if (value is List) return value;
        return <dynamic>[];

      default:
        return value;
    }
  }

  /// Split/normalize a Select-MultiSelect-style value into a list of strings.
  static List<String> _normalizeMultiSelect(dynamic value) {
    if (value == null) return <String>[];
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }
    final raw = value.toString();
    if (raw.isEmpty) return <String>[];
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }
}
