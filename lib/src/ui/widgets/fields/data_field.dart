import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// How close to `maxLength` the input must get before the character counter
/// is revealed. Below this the counter stays hidden so the field matches the
/// web UI's clean look; a field whose cap is smaller than this window (a short
/// explicit `DocField.length`) always shows it — every keystroke is "near the
/// cap" there.
const int _counterRevealWindow = 20;

/// Widget for Data field type
class DataField extends BaseField {
  /// When false (e.g. a Single doctype, which Frappe stores as mediumtext),
  /// skip the implicit varchar(140) cap on a `Data` field whose
  /// `DocField.length` is unset. Default true — cap, matching Frappe's
  /// non-Single behaviour.
  final bool capLength;
  const DataField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.capLength = true,
  });

  @override
  Widget buildField(BuildContext context) {
    final isPhone = field.fieldtype == 'Phone';
    final editable = enabled && !field.readOnly;

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
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('data_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: initialValue,
      enabled: editable,
      inputFormatters: style?.inputFormatters,
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
      // Frappe `Data` columns are varchar(140) by default (implicit when
      // DocField.length is unset) — cap on-device so free-text can't overflow
      // and fail server-side with a 417 (CharacterLengthExceededError) only at
      // sync. [capLength] is false for Single doctypes, which Frappe stores as
      // mediumtext and exempts from the cap entirely (regardless of any
      // explicit length).
      maxLength: capLength
          ? ((field.length != null && field.length! > 0) ? field.length : 140)
          : null,
      // The cap must not be SILENT: `maxLength` makes the field simply stop
      // registering keystrokes, so with no counter the user gets no reason.
      // Show the counter only once they are within [_counterRevealWindow]
      // characters of the cap — below that the field stays as clean as the web
      // UI, which is the common case. A non-editable field never truncates a
      // keystroke, so it stays counter-free at any length (this also covers
      // FieldFactory's `default:` branch, which renders unsupported field types
      // as a disabled DataField holding an arbitrarily long value).
      buildCounter:
          (
            BuildContext context, {
            required int currentLength,
            required bool isFocused,
            int? maxLength,
          }) {
            if (maxLength == null || !editable) return null;
            if (currentLength < maxLength - _counterRevealWindow) return null;
            final atCap = currentLength >= maxLength;
            return Text(
              '$currentLength/$maxLength',
              semanticsLabel: '$currentLength of $maxLength characters',
              style: TextStyle(
                fontSize: 12,
                color: atCap
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).hintColor,
              ),
            );
          },
      validator: field.reqd
          ? (value) {
              final required = requiredValidator(value, field.displayLabel);
              if (required != null) return required;
              // Phone validation - must start with + and country code
              if (isPhone && value!.isNotEmpty) {
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
