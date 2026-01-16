import 'package:flutter/material.dart';
import '../../../models/doc_field.dart';

/// Customization options for field styling
class FieldStyle {
  final TextStyle? labelStyle;
  final TextStyle? descriptionStyle;
  final InputDecoration? decoration;

  const FieldStyle({
    this.labelStyle,
    this.descriptionStyle,
    this.decoration,
  });
}

/// Base class for all Frappe field widgets
abstract class BaseField extends StatelessWidget {
  final DocField field;
  final dynamic value;
  final ValueChanged<dynamic>? onChanged;
  final bool enabled;
  final FieldStyle? style;

  const BaseField({
    super.key,
    required this.field,
    this.value,
    this.onChanged,
    this.enabled = true,
    this.style,
  });

  /// Build the field widget
  @override
  Widget build(BuildContext context) {
    if (field.hidden) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (field.label != null && field.label!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Row(
              children: [
                Text(
                  field.displayLabel,
                  style: style?.labelStyle ?? TextStyle(
                    fontWeight: field.reqd ? FontWeight.bold : FontWeight.normal,
                    fontSize: 14,
                  ),
                ),
                if (field.reqd)
                  const Padding(
                    padding: EdgeInsets.only(left: 4.0),
                    child: Text(
                      '*',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
          ),
        buildField(context),
        if (field.description != null && field.description!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(
              field.description!,
              style: style?.descriptionStyle ?? 
                  Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
          ),
      ],
    );
  }

  /// Build the actual input widget (to be implemented by subclasses)
  Widget buildField(BuildContext context);

  /// Validate the field value
  String? validate(dynamic value) {
    if (field.reqd && (value == null || value.toString().isEmpty)) {
      return '${field.displayLabel} is required';
    }
    return null;
  }
}
