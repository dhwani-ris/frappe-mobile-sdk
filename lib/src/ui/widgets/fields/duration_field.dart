// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for Duration field type (in seconds)
class DurationField extends BaseField {
  const DurationField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;
    
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  int? _parseDuration(String? value) {
    if (value == null || value.isEmpty) return null;
    
    // Try parsing as integer (seconds)
    final intValue = int.tryParse(value);
    if (intValue != null) return intValue;
    
    // Try parsing HH:MM:SS format
    final parts = value.split(':');
    if (parts.length == 3) {
      final hours = int.tryParse(parts[0]);
      final minutes = int.tryParse(parts[1]);
      final seconds = int.tryParse(parts[2]);
      if (hours != null && minutes != null && seconds != null) {
        return hours * 3600 + minutes * 60 + seconds;
      }
    } else if (parts.length == 2) {
      final minutes = int.tryParse(parts[0]);
      final seconds = int.tryParse(parts[1]);
      if (minutes != null && seconds != null) {
        return minutes * 60 + seconds;
      }
    }
    
    return null;
  }

  @override
  Widget buildField(BuildContext context) {
    int? initialSeconds;
    if (value != null) {
      if (value is int) {
        initialSeconds = value;
      } else if (value is String) {
        initialSeconds = _parseDuration(value);
      }
    }

    return FormBuilderTextField(
      key: ValueKey('${field.fieldname}_${initialSeconds ?? ''}'),
      name: field.fieldname ?? '',
      initialValue: initialSeconds != null ? _formatDuration(initialSeconds) : null,
      enabled: enabled && !field.readOnly,
      keyboardType: TextInputType.number,
      decoration: style?.decoration ?? InputDecoration(
        hintText: field.placeholder ?? 'HH:MM:SS or seconds',
        border: const OutlineInputBorder(),
        filled: field.readOnly,
        fillColor: field.readOnly ? Colors.grey[200] : null,
        helperText: 'Format: HH:MM:SS or seconds',
      ),
      validator: field.reqd
          ? (value) {
              if (value == null || value.isEmpty) {
                return '${field.displayLabel} is required';
              }
              if (_parseDuration(value) == null) {
                return 'Invalid duration format';
              }
              return null;
            }
          : (value) {
              if (value != null && value.isNotEmpty && _parseDuration(value) == null) {
                return 'Invalid duration format';
              }
              return null;
            },
      onChanged: (val) {
        final seconds = _parseDuration(val);
        onChanged?.call(seconds);
      },
    );
  }
}
