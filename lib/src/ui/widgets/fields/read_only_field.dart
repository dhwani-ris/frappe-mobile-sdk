// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for Read Only field type
class ReadOnlyField extends BaseField {
  const ReadOnlyField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    final displayValue = value?.toString() ?? field.defaultValue ?? '';
    
    return FormBuilderTextField(
      key: ValueKey('${field.fieldname}_$displayValue'),
      name: field.fieldname ?? '',
      initialValue: displayValue,
      enabled: false,
      readOnly: true,
      decoration: style?.decoration ?? InputDecoration(
        hintText: field.placeholder,
        border: const OutlineInputBorder(),
        filled: true,
        fillColor: Colors.grey[200],
        helperText: field.description,
      ),
    );
  }
}
