// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// Widget for Rating field type.
///
/// Frappe persists a Rating as a **0..1 fraction** — `stars / max_stars` — not
/// as a star count. Ten stars out of ten is `1`, three out of five is `0.6`.
/// `options` carries the number of stars (default 5).
///
/// This widget therefore stores and emits a `double` in 0..1 and renders
/// `round(value * maxRating)` filled stars. It previously emitted an `int` star
/// count, which meant a mobile-authored rating was written on a different scale
/// from every other client, and a value authored elsewhere (e.g. `0.6`) failed
/// to parse as an `int` and rendered as **zero stars**.
class RatingField extends BaseField {
  const RatingField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  /// Number of stars this Rating renders — Frappe puts it in `options`.
  static int maxRatingFor(String? options) {
    if (options == null) return 5;
    for (final line in options.split('\n')) {
      final n = int.tryParse(line.trim());
      if (n != null && n > 0) return n;
    }
    return 5;
  }

  /// Stored 0..1 fraction -> number of filled stars.
  ///
  /// Accepts `num` and `String` so a value straight from SQLite (real), from
  /// JSON (num), or from a form-data round-trip (String) all resolve.
  static int starsFromStored(dynamic stored, int maxRating) {
    final n = stored is num ? stored.toDouble() : double.tryParse('$stored');
    if (n == null || n <= 0) return 0;
    // Guard against a legacy value already written as a star count (> 1).
    final fraction = n > 1 ? n / maxRating : n;
    return (fraction * maxRating).round().clamp(0, maxRating);
  }

  /// Number of filled stars -> the 0..1 fraction Frappe stores.
  static double storedFromStars(int stars, int maxRating) =>
      maxRating <= 0 ? 0 : stars / maxRating;

  @override
  Widget buildField(BuildContext context) {
    final maxRating = maxRatingFor(field.options);
    final initialFraction = value == null
        ? null
        : storedFromStars(starsFromStored(value, maxRating), maxRating);

    return FormBuilderField<double>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('rating_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: initialFraction,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      builder: (FormFieldState<double> fieldState) {
        // BaseField.build already renders the external label with
        // required-asterisk; the inline label that used to live here is
        // gone for parity with text/numeric/etc field widgets.
        final filled = starsFromStored(fieldState.value, maxRating);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: List.generate(maxRating, (index) {
                final rating = index + 1;
                final isSelected = filled >= rating;
                return GestureDetector(
                  onTap: enabled && !field.readOnly
                      ? () {
                          // Re-tapping the currently-last filled star clears the
                          // rating, matching the web SPA (FieldInput.vue:379).
                          final stars = filled == rating ? 0 : rating;
                          final next = storedFromStars(stars, maxRating);
                          fieldState.didChange(next);
                          onChanged?.call(next);
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
