// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:intl/intl.dart';
import 'base_field.dart';

/// Widget for Time field type
class TimeField extends BaseField {
  const TimeField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    TimeOfDay? initialTime;
    if (value != null) {
      if (value is TimeOfDay) {
        initialTime = value;
      } else if (value is String) {
        final parts = value.split(':');
        if (parts.length >= 2) {
          final hour = int.tryParse(parts[0]);
          final minute = int.tryParse(parts[1]);
          if (hour != null && minute != null) {
            initialTime = TimeOfDay(hour: hour, minute: minute);
          }
        }
      }
    }

    return FormBuilderDateTimePicker(
      key: ValueKey('${field.fieldname}_${initialTime?.format(context) ?? ''}'),
      name: field.fieldname ?? '',
      initialValue: initialTime != null
          ? DateTime(2000, 1, 1, initialTime.hour, initialTime.minute)
          : null,
      enabled: enabled && !field.readOnly,
      inputType: InputType.time,
      format: DateFormat('HH:mm:ss'),
      decoration:
          style?.decoration ??
          InputDecoration(
            hintText: field.placeholder ?? 'Select time',
            border: const OutlineInputBorder(),
            filled: field.readOnly,
            fillColor: field.readOnly ? Colors.grey[200] : null,
            suffixIcon: const Icon(Icons.access_time),
          ),
      validator: field.reqd
          ? (value) {
              if (value == null) {
                return '${field.displayLabel} is required';
              }
              return null;
            }
          : null,
      onChanged: (val) {
        if (val != null) {
          final timeStr = DateFormat('HH:mm:ss').format(val);
          onChanged?.call(timeStr);
        }
      },
    );
  }
}
