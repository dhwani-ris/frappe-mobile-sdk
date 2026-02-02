// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for Rating field type
class RatingField extends BaseField {
  const RatingField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    int maxRating = 5;
    if (field.options != null) {
      final options = field.options!
          .split('\n')
          .where((o) => o.trim().isNotEmpty)
          .toList();
      if (options.isNotEmpty) {
        maxRating = int.tryParse(options.first) ?? 5;
      }
    }

    int? initialRating;
    if (value != null) {
      if (value is int) {
        initialRating = value;
      } else if (value is String) {
        initialRating = int.tryParse(value);
      }
    }

    return FormBuilderField<int>(
      key: ValueKey('${field.fieldname}_${initialRating ?? ''}'),
      name: field.fieldname ?? '',
      initialValue: initialRating,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) {
              if (value == null) {
                return '${field.displayLabel} is required';
              }
              return null;
            }
          : null,
      builder: (FormFieldState<int> fieldState) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (field.label != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(field.label!, style: style?.labelStyle),
              ),
            Row(
              children: List.generate(maxRating, (index) {
                final rating = index + 1;
                final isSelected =
                    fieldState.value != null && fieldState.value! >= rating;
                return GestureDetector(
                  onTap: enabled && !field.readOnly
                      ? () {
                          fieldState.didChange(rating);
                          onChanged?.call(rating);
                        }
                      : null,
                  child: Icon(
                    isSelected ? Icons.star : Icons.star_border,
                    color: isSelected ? Colors.amber : Colors.grey,
                    size: 32,
                  ),
                );
              }),
            ),
            if (fieldState.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  fieldState.errorText!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        );
      },
    );
  }
}
