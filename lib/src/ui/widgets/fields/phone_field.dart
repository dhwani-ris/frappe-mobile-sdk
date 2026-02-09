import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Default country code (India)
const String _defaultDialCode = '+91';

/// Widget for Phone field type. Uses fixed +91 prefix; user enters mobile number only.
class PhoneField extends BaseField {
  const PhoneField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  /// Full stored value is dialCode + digits (e.g. +919876543210)
  static String _digitsOnly(String? s) {
    if (s == null) return '';
    return s.replaceAll(RegExp(r'[^\d]'), '');
  }

  /// From full value (e.g. +919876543210) get number part without country code.
  /// If stored is only "91" or "+91", returns '' so field is empty.
  static String numberFromStored(String? stored) {
    if (stored == null || stored.isEmpty) return '';
    final digits = _digitsOnly(stored);
    const codeDigits = '91';
    if (digits == codeDigits || digits.isEmpty) return '';
    if (digits.startsWith(codeDigits) && digits.length > 2) {
      return digits.substring(codeDigits.length);
    }
    return digits;
  }

  /// Build stored value: +91 + number digits
  static String toStored(String numberDigits) {
    final digits = _digitsOnly(numberDigits);
    if (digits.isEmpty) return '';
    return '$_defaultDialCode$digits';
  }

  @override
  Widget buildField(BuildContext context) {
    final stored = value?.toString() ?? field.defaultValue ?? '';
    final numberPart = numberFromStored(stored);

    return FormBuilderTextField(
      key: ValueKey('phone_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: numberPart,
      enabled: enabled && !field.readOnly,
      keyboardType: TextInputType.phone,
      decoration:
          style?.decoration ??
          InputDecoration(
            hintText: field.placeholder ?? 'Enter mobile number',
            border: const OutlineInputBorder(),
            filled: field.readOnly,
            fillColor: field.readOnly ? Colors.grey[200] : null,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 16,
            ),
          ),
      maxLength: (field.length != null && field.length! > 0)
          ? field.length
          : 10,
      validator: field.reqd
          ? (value) {
              if (value == null || value.toString().trim().isEmpty) {
                return '${field.displayLabel} is required';
              }
              final digits = _digitsOnly(value);
              if (digits.length < 10) {
                return 'Please enter a valid 10-digit mobile number';
              }
              return null;
            }
          : (value) {
              if (value != null && value.toString().trim().isNotEmpty) {
                final digits = _digitsOnly(value);
                if (digits.length < 10) {
                  return 'Please enter a valid 10-digit mobile number';
                }
              }
              return null;
            },
      onChanged: (val) {
        final storedValue = toStored(val ?? '');
        onChanged?.call(storedValue.isEmpty ? null : storedValue);
      },
    );
  }
}
