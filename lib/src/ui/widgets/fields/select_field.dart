import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../../utils/frappe_reserved_fields.dart';
import '../../../utils/translate.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// Widget for Select field type. Supports single and multi-select (when field.allowMultiple).
class SelectField extends BaseField {
  /// When false, the single-option preselect below never fires for this
  /// field. `FieldFactory` sets it from [isFrappeReservedField] so a
  /// framework-owned slot (`naming_series`, `amended_from`, the `is_tree`
  /// `parent_<doctype>` Link, …) is never filled with a value the user did not
  /// choose. Defaults to true so a host constructing this widget directly
  /// keeps the previous behaviour.
  final bool allowPreselect;

  const SelectField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.allowPreselect = true,
  });

  /// Raw (untranslated) option keys — used as stored document values.
  ///
  /// Deduplicated, order-preserving: `DropdownButton` asserts when two
  /// `DropdownMenuItem`s share the value it is showing ("There should be
  /// exactly one item with [DropdownButton]'s value"), so a DocType whose
  /// `options` repeats a line would crash the field outright. Deduping also
  /// restores the preselect for a sole option that happens to be written
  /// twice — the count is 1 again, not 2.
  List<String> _getRawOptions() {
    if (field.options == null || field.options!.isEmpty) return [];
    return LinkedHashSet<String>.of(
      field.options!
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty),
    ).toList();
  }

  /// Whether the single-option preselect may fire.
  ///
  /// `value == null` is the load-bearing clause: it fires only when the form
  /// holds NO ENTRY for this field, not merely when the entry is unusable.
  ///
  /// It has TWO callers, and only the first is a bug fix:
  ///
  ///  1. An EXPLICIT clear stores `''` (multi-select emits
  ///     `_listToValue([])`). Preselecting on "no valid selection" alone made
  ///     "cleared" and "never set" indistinguishable, so unchecking the sole
  ///     option of a multi-select re-fired the preselect on the very next
  ///     build and pushed the value back — while `FormBuilderCheckboxGroup`,
  ///     whose `ValueKey` had not changed, stayed visibly unchecked. The
  ///     widget and the form data then disagreed, and `_handleSubmit`'s
  ///     `formValues.addAll(_formData)` let the form data win.
  ///
  ///  2. A PULLED DOCUMENT also arrives holding `''`, and is the more common
  ///     caller by far. Frappe stores an unset Select as `varchar NOT NULL
  ///     DEFAULT ''` and returns `""`; the pull writes that verbatim and
  ///     `FrappeFormBuilder`'s `_formData.addAll(widget.initialData ?? {})`
  ///     normalises nothing in between. So a synced record with a one-option
  ///     Select is NOT auto-filled, and with `reqd: 1` the user must pick the
  ///     sole choice by hand. That is deliberate: auto-filling a synced record
  ///     writes a value the user never chose and dirties the document on open.
  ///     In practice preselect now fires only on documents this device
  ///     created.
  ///
  /// Keying on `value == null` rather than `!formData.containsKey(fieldname)`
  /// is also the convention this repo settled on in `843b86b` — an unsaved doc
  /// is routinely assembled with explicit `null` entries, so key presence is
  /// the trap.
  ///
  /// NOTE: `LinkField` deliberately does NOT share this gate. Both of its
  /// preselect sites still test "no valid selection"
  /// (`validInitialValue == null || validInitialValue.isEmpty` for static
  /// options, `!hasValidSelection` for service-loaded ones), so a single-option
  /// Link DOES still preselect over the `''` of a pulled document. Pinned by
  /// `link_field_preselect_test.dart`'s "an empty stored value" group. The
  /// clear/re-fire loop above is specific to the multi-select checkbox path,
  /// which `LinkField` has no equivalent of; aligning the two is a behaviour
  /// change on its own evidence, not a ride-along.
  bool get _canPreselect =>
      allowPreselect && enabled && !field.readOnly && value == null;

  /// Translated display labels — used only for rendering.
  List<String> _getOptions() {
    final raw = _getRawOptions();
    final t = style?.translate;
    return t == null ? raw : raw.map(t).toList();
  }

  /// Parse stored value to list for multi-select (comma-separated)
  List<String> _valueToList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    return raw
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// Serialize list to comma-separated string for form/server
  String _listToValue(List<String>? list) {
    if (list == null || list.isEmpty) return '';
    return list.join(',');
  }

  @override
  Widget buildField(BuildContext context) {
    // rawOptions: English keys used for stored values and equality checks.
    // displayOptions: translated labels used only for display (Text children).
    final rawOptions = _getRawOptions();
    final displayOptions = _getOptions();

    if (rawOptions.isEmpty) {
      return FormBuilderTextField(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        key: ValueKey('${field.fieldname}_no_options'),
        name: field.fieldname ?? '',
        initialValue: value?.toString() ?? field.defaultValue ?? '',
        enabled: false,
        decoration:
            style?.decoration ??
            InputDecoration(
              hintText: sdkTr('No options available'),
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.grey[200],
            ),
      );
    }

    if (field.allowMultiple) {
      final initialList = _valueToList(value?.toString() ?? field.defaultValue);
      // Match against raw English keys, not translated labels.
      final validInitialList = initialList
          .where((v) => rawOptions.contains(v))
          .toList();

      // Preselect when exactly one option and nothing is selected yet.
      // Use raw English key for the stored value. See [_canPreselect] for why
      // an explicitly-cleared value ('') is excluded.
      final preselect =
          rawOptions.length == 1 && validInitialList.isEmpty && _canPreselect;
      final displayList = preselect ? [rawOptions.first] : validInitialList;
      if (preselect) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onChanged?.call(_listToValue([rawOptions.first]));
        });
      }

      return FormBuilderCheckboxGroup<String>(
        autovalidateMode: AutovalidateMode.onUserInteraction,
        key: ValueKey('${field.fieldname}_multi_${rawOptions.length}'),
        name: field.fieldname ?? '',
        initialValue: displayList,
        enabled: enabled && !field.readOnly,
        decoration:
            style?.decoration ??
            InputDecoration(
              labelText:
                  field.placeholder ??
                  sdkTr('Select {0}', [field.displayLabel]),
              border: const OutlineInputBorder(),
              filled: field.readOnly,
              fillColor: field.readOnly ? Colors.grey[200] : null,
            ),
        // value: raw English key (stored value); child: translated display label.
        options: rawOptions.asMap().entries.map((entry) {
          return FormBuilderFieldOption(
            value: entry.value,
            child: Text(displayOptions[entry.key]),
          );
        }).toList(),
        validator: field.reqd
            ? (value) => requiredValidator(value, field.displayLabel)
            : null,
        onChanged: (val) => onChanged?.call(_listToValue(val)),
      );
    }

    final initialValueStr = value?.toString() ?? field.defaultValue;
    String? validInitialValue;
    if (initialValueStr != null && initialValueStr.isNotEmpty) {
      // Match against raw English keys, not translated labels.
      if (rawOptions.contains(initialValueStr)) {
        validInitialValue = initialValueStr;
      } else {
        validInitialValue = null;
      }
    }

    // Preselect when exactly one option and nothing is selected yet.
    // Emit raw English key — never a translated label.
    if (rawOptions.length == 1 &&
        (validInitialValue == null || validInitialValue.isEmpty) &&
        _canPreselect) {
      validInitialValue = rawOptions.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onChanged?.call(rawOptions.first);
      });
    }

    // A non-empty incoming value that is not one of the current options is a
    // stale selection (option removed/renamed, or an old saved record). It is
    // coerced to null (above) so FormBuilderDropdown never asserts; surface a
    // hint so the dropped value is visible rather than silently lost.
    final hasStaleValue =
        initialValueStr != null &&
        initialValueStr.isNotEmpty &&
        validInitialValue == null;
    final baseDecoration =
        style?.decoration ??
        InputDecoration(
          hintText:
              field.placeholder ?? sdkTr('Select {0}', [field.displayLabel]),
          border: const OutlineInputBorder(),
          filled: field.readOnly,
          fillColor: field.readOnly ? Colors.grey[200] : null,
        );
    final effectiveDecoration = hasStaleValue
        ? baseDecoration.copyWith(
            helperText: sdkTr(
              'Previously saved value is no longer an available option',
            ),
            helperMaxLines: 2,
          )
        : baseDecoration;
    // Move the decoration's horizontal padding into the dropdown's own
    // (clickable) padding so the entire bordered box opens the menu, not just
    // the area inside the content padding. See [dropdownFullTap].
    final tap = dropdownFullTap(effectiveDecoration);

    return FormBuilderDropdown<String>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('select_${field.fieldname}_${rawOptions.length}'),
      name: field.fieldname ?? '',
      initialValue: validInitialValue,
      enabled: enabled && !field.readOnly,
      isExpanded: true,
      decoration: tap.decoration,
      padding: tap.padding,
      // value: raw English key (stored value); child: translated display label.
      items: rawOptions.asMap().entries.map((entry) {
        return DropdownMenuItem<String>(
          value: entry.value,
          child: Text(displayOptions[entry.key]),
        );
      }).toList(),
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      onChanged: (val) => onChanged?.call(val),
    );
  }
}
