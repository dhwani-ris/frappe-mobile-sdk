import 'package:flutter/material.dart';

import '../../../models/doc_field.dart';
import 'base_field.dart';

/// `validator` for a required field. Returns the standard
/// `'$label is required'` message when [value] is null OR its string form
/// is empty; null otherwise (valid). Shared by every field widget that
/// wires a non-null `validator:` callback so the message text and the
/// null-or-empty check do not drift between widgets. Use
/// `(value) => requiredValidator(value, field.displayLabel)` (or fold
/// translation through [BaseField.style]) at the call site.
String? requiredValidator(dynamic value, String label) {
  if (value == null || value.toString().isEmpty) {
    return '$label is required';
  }
  return null;
}

/// Returns an `InputDecoration` that applies the SDK's read-only fill
/// (grey-200 background when `field.readOnly`) on top of any caller-provided
/// [style] decoration. Used by every text-shaped field widget so a change
/// to the read-only theming applies everywhere at once.
InputDecoration baseFieldDecoration(
  DocField field, {
  String? hint,
  FieldStyle? style,
}) {
  return style?.decoration ??
      InputDecoration(
        hintText: hint ?? field.placeholder,
        border: const OutlineInputBorder(),
        filled: field.readOnly,
        fillColor: field.readOnly ? Colors.grey[200] : null,
      );
}

/// Renders the field's validation error in the standard red 12px style
/// underneath the input. Used by the custom `FormBuilderField.builder`
/// field widgets (attach, image, rating) that build their own column and
/// need to surface `fieldState.errorText` manually.
Widget fieldErrorText(FormFieldState fieldState) {
  if (!fieldState.hasError) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 4.0),
    child: Text(
      fieldState.errorText!,
      style: const TextStyle(color: Colors.red, fontSize: 12),
    ),
  );
}
