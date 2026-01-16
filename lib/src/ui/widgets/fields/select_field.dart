import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for Select field type
class SelectField extends BaseField {
  const SelectField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  List<String> _getOptions() {
    if (field.options == null || field.options!.isEmpty) {
      return [];
    }
    return field.options!.split('\n').where((e) => e.isNotEmpty).toList();
  }

  @override
  Widget buildField(BuildContext context) {
    final options = _getOptions();

    // If no options available, show a message (matching frappe_huf behavior)
    if (options.isEmpty) {
      return FormBuilderTextField(
        key: ValueKey('${field.fieldname}_no_options'),
        name: field.fieldname ?? '',
        initialValue: value?.toString() ?? field.defaultValue ?? '',
        enabled: false,
        decoration: style?.decoration ?? InputDecoration(
          hintText: 'No options available',
          border: const OutlineInputBorder(),
          filled: true,
          fillColor: Colors.grey[200],
        ),
      );
    }

    // Validate initialValue is in options list
    final initialValueStr = value?.toString() ?? field.defaultValue;
    String? validInitialValue;
    if (initialValueStr != null && initialValueStr.isNotEmpty) {
      if (options.contains(initialValueStr)) {
        validInitialValue = initialValueStr;
      } else {
        // Value not in options - use null or first option
        validInitialValue = null;
      }
    }

    return FormBuilderDropdown<String>(
      key: ValueKey('${field.fieldname}_${validInitialValue ?? ''}_${options.length}'),
      name: field.fieldname ?? '',
      initialValue: validInitialValue,
      enabled: enabled && !field.readOnly,
      decoration: style?.decoration ?? InputDecoration(
        hintText: field.placeholder ?? 'Select ${field.displayLabel}',
        border: const OutlineInputBorder(),
        filled: field.readOnly,
        fillColor: field.readOnly ? Colors.grey[200] : null,
      ),
      items: options.map((option) {
        return DropdownMenuItem<String>(
          value: option,
          child: Text(option),
        );
      }).toList(),
      validator: field.reqd
          ? (value) {
              if (value == null || value.toString().isEmpty) {
                return '${field.displayLabel} is required';
              }
              return null;
            }
          : null,
      onChanged: (val) => onChanged?.call(val),
    );
  }
}
