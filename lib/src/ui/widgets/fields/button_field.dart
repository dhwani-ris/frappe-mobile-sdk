// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import '../../../models/doc_field.dart';
import 'base_field.dart';

/// Widget for Button field type.
/// Renders a clickable button that invokes an optional server method (from field.options)
/// or a custom handler via [onButtonPressed].
/// Does not register with FormBuilder - Button holds no form value.
class ButtonField extends BaseField {
  /// Called when the button is pressed. Receives the field and current form data.
  /// When [field.options] contains a server method path, the caller typically
  /// invokes FrappeClient.call(field.options!, args: {'doc': formData}).
  final Future<void> Function(DocField field, Map<String, dynamic> formData)?
  onButtonPressed;

  /// Current form data (passed to [onButtonPressed] when invoking server method).
  final Map<String, dynamic>? formData;

  const ButtonField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.onButtonPressed,
    this.formData,
  });

  @override
  Widget build(BuildContext context) {
    if (field.hidden) {
      return const SizedBox.shrink();
    }

    // For Button, the label IS the button text - no separate label row
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildField(context),
        if (field.description != null && field.description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              field.description!,
              style:
                  style?.descriptionStyle ??
                  Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
            ),
          ),
      ],
    );
  }

  @override
  Widget buildField(BuildContext context) {
    return _ButtonFieldStateful(
      field: field,
      enabled: enabled,
      onButtonPressed: onButtonPressed,
      formData: formData ?? const {},
    );
  }
}

/// Stateful wrapper to manage loading state during async onButtonPressed.
class _ButtonFieldStateful extends StatefulWidget {
  final DocField field;
  final bool enabled;
  final Future<void> Function(DocField field, Map<String, dynamic> formData)?
  onButtonPressed;
  final Map<String, dynamic> formData;

  const _ButtonFieldStateful({
    required this.field,
    required this.enabled,
    required this.onButtonPressed,
    required this.formData,
  });

  @override
  State<_ButtonFieldStateful> createState() => _ButtonFieldStatefulState();
}

class _ButtonFieldStatefulState extends State<_ButtonFieldStateful> {
  bool _isLoading = false;

  Future<void> _handlePressed() async {
    if (widget.onButtonPressed == null || _isLoading || !widget.enabled) return;
    setState(() => _isLoading = true);
    try {
      await widget.onButtonPressed!(widget.field, widget.formData);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPress =
        widget.enabled && !_isLoading && widget.onButtonPressed != null;

    return ElevatedButton(
      onPressed: canPress ? _handlePressed : null,
      child: _isLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(widget.field.displayLabel),
    );
  }
}
