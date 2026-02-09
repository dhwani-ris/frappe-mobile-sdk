import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for Check (Boolean) field type
class CheckField extends BaseField {
  const CheckField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    bool initialValue = false;
    if (value != null) {
      if (value is bool) {
        initialValue = value;
      } else if (value is int) {
        initialValue = value == 1;
      } else if (value is String) {
        initialValue = value == '1' || value.toLowerCase() == 'true';
      }
    } else if (field.defaultValue != null) {
      initialValue =
          field.defaultValue == '1' ||
          field.defaultValue!.toLowerCase() == 'true';
    }

    return FormBuilderSwitch(
      key: ValueKey('check_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: initialValue,
      enabled: enabled && !field.readOnly,
      title: Text(field.placeholder ?? field.displayLabel),
      onChanged: (val) {
        if (val != null) {
          onChanged?.call(val ? 1 : 0);
        }
      },
    );
  }
}
