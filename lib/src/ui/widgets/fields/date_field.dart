import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:intl/intl.dart';
import 'base_field.dart';

/// Widget for Date field type
class DateField extends BaseField {
  const DateField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    DateTime? initialDate;
    if (value != null) {
      if (value is DateTime) {
        initialDate = value;
      } else if (value is String) {
        initialDate = DateTime.tryParse(value);
      }
    }

    return FormBuilderDateTimePicker(
      key: ValueKey(
        '${field.fieldname}_${initialDate?.toIso8601String() ?? ''}',
      ),
      name: field.fieldname ?? '',
      initialValue: initialDate,
      enabled: enabled && !field.readOnly,
      inputType: InputType.date,
      format: DateFormat('yyyy-MM-dd'),
      decoration:
          style?.decoration ??
          InputDecoration(
            hintText: field.placeholder ?? 'Select date',
            border: const OutlineInputBorder(),
            filled: field.readOnly,
            fillColor: field.readOnly ? Colors.grey[200] : null,
            suffixIcon: const Icon(Icons.calendar_today),
          ),
      validator: field.reqd
          ? (value) {
              if (value == null) {
                return '${field.displayLabel} is required';
              }
              return null;
            }
          : null,
      onChanged: (val) => onChanged?.call(val?.toIso8601String()),
    );
  }
}
