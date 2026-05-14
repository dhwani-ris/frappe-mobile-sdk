// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import 'field_helpers.dart';

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
      key: ValueKey('rating_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: initialRating,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      builder: (FormFieldState<int> fieldState) {
        // BaseField.build already renders the external label with
        // required-asterisk; the inline label that used to live here is
        // gone for parity with text/numeric/etc field widgets.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
            fieldErrorText(fieldState),
          ],
        );
      },
    );
  }
}
