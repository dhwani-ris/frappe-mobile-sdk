// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:intl/intl.dart';
import '../../../utils/date_helpers.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// Widget for Datetime field type
class DatetimeField extends BaseField {
  const DatetimeField({
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
      key: ValueKey('datetime_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: parseDateTime(value),
      enabled: enabled && !field.readOnly,
      inputType: InputType.both,
      format: DateFormat('yyyy-MM-dd HH:mm:ss'),
      decoration:
          style?.decoration ??
          InputDecoration(
            hintText: field.placeholder ?? 'Select date and time',
            border: const OutlineInputBorder(),
            filled: field.readOnly,
            fillColor: field.readOnly ? Colors.grey[200] : null,
            suffixIcon: const Icon(Icons.access_time),
          ),
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      onChanged: (val) => onChanged?.call(val?.toIso8601String()),
    );
  }
}
