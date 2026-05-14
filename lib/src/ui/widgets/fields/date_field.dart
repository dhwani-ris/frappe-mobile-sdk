import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:intl/intl.dart';
import '../../../utils/date_helpers.dart';
import 'base_field.dart';
import 'field_helpers.dart';

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
    return FormBuilderDateTimePicker(
      key: ValueKey('date_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: parseDateTime(value),
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
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      onChanged: (val) => onChanged?.call(val?.toIso8601String()),
    );
  }
}
