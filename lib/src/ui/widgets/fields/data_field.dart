import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for Data field type
class DataField extends BaseField {
  const DataField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    final isPhone = field.fieldtype == 'Phone';

    // Ensure phone values start with + (required by Frappe)
    String? initialValue = value?.toString() ?? field.defaultValue ?? '';
    if (isPhone && initialValue.isNotEmpty && !initialValue.startsWith('+')) {
      initialValue = '+$initialValue';
    }

    // Get hint text - add country code hint for phone fields if no placeholder
    String? hintText = field.placeholder;
    if (isPhone && (hintText == null || hintText.isEmpty)) {
      hintText = 'e.g., +91XXXXXXXXXX';
    }

    return FormBuilderTextField(
      key: ValueKey('data_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: initialValue,
      enabled: enabled && !field.readOnly,
      keyboardType: isPhone ? TextInputType.phone : TextInputType.text,
      decoration:
          style?.decoration ??
          InputDecoration(
            hintText: hintText,
            border: const OutlineInputBorder(),
            filled: field.readOnly,
            fillColor: field.readOnly ? Colors.grey[200] : null,
            helperText: isPhone
                ? 'Must include country code (e.g., +91 for India)'
                : null,
            helperMaxLines: 2,
          ),
      maxLength: (field.length != null && field.length! > 0)
          ? field.length
          : null,
      validator: field.reqd
          ? (value) {
              if (value == null || value.toString().isEmpty) {
                return '${field.displayLabel} is required';
              }
              // Phone validation - must start with + and country code
              if (isPhone && value.isNotEmpty) {
                final trimmed = value.trim();
                // Check if it starts with + (required by Frappe)
                if (!trimmed.startsWith('+')) {
                  return 'Phone number must start with country code (e.g., +91)';
                }
                // Remove + and common formatting characters for validation
                final cleaned = trimmed
                    .substring(1)
                    .replaceAll(RegExp(r'[\s\-\(\)]'), '');
                // Country code (1-3 digits) + phone number (7-12 digits) = 8-15 total digits
                if (!RegExp(r'^[0-9]{8,15}$').hasMatch(cleaned)) {
                  return 'Please enter a valid phone number with country code';
                }
              }
              return null;
            }
          : isPhone
          ? (value) {
              // Optional validation for non-required phone fields
              if (value != null && value.isNotEmpty) {
                final trimmed = value.trim();
                if (!trimmed.startsWith('+')) {
                  return 'Phone number must start with country code (e.g., +91)';
                }
                final cleaned = trimmed
                    .substring(1)
                    .replaceAll(RegExp(r'[\s\-\(\)]'), '');
                if (!RegExp(r'^[0-9]{8,15}$').hasMatch(cleaned)) {
                  return 'Please enter a valid phone number with country code';
                }
              }
              return null;
            }
          : null,
      onChanged: (val) {
        if (val == null || val.isEmpty) {
          onChanged?.call(val);
          return;
        }

        // For phone fields, ensure + prefix is maintained
        if (isPhone) {
          final trimmed = val.trim();
          // If user types without +, auto-prepend it
          if (!trimmed.startsWith('+')) {
            onChanged?.call('+$trimmed');
          } else {
            onChanged?.call(trimmed);
          }
        } else {
          onChanged?.call(val);
        }
      },
    );
  }
}
