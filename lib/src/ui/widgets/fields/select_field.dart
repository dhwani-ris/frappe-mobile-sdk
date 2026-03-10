import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for Select field type. Supports single and multi-select (when field.allowMultiple).
class SelectField extends BaseField {
  const SelectField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  List<String> _getOptions() {
    if (field.options == null || field.options!.isEmpty) {
      return [];
    }
    return field.options!.split('\n').where((e) => e.isNotEmpty).toList();
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
    final options = _getOptions();

    if (options.isEmpty) {
      return FormBuilderTextField(
        key: ValueKey('${field.fieldname}_no_options'),
        name: field.fieldname ?? '',
        initialValue: value?.toString() ?? field.defaultValue ?? '',
        enabled: false,
        decoration:
            style?.decoration ??
            InputDecoration(
              hintText: 'No options available',
              border: const OutlineInputBorder(),
              filled: true,
              fillColor: Colors.grey[200],
            ),
      );
    }

    if (field.allowMultiple) {
      final initialList = _valueToList(value?.toString() ?? field.defaultValue);
      final validInitialList = initialList
          .where((v) => options.contains(v))
          .toList();

      // Auto-select when exactly one option and no valid selection
      final displayList = options.length == 1 && validInitialList.isEmpty
          ? [options.first]
          : validInitialList;
      if (options.length == 1 && validInitialList.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onChanged?.call(_listToValue([options.first]));
        });
      }

      return FormBuilderCheckboxGroup<String>(
        key: ValueKey('${field.fieldname}_multi_${options.length}'),
        name: field.fieldname ?? '',
        initialValue: displayList,
        enabled: enabled && !field.readOnly,
        decoration:
            style?.decoration ??
            InputDecoration(
              labelText: field.placeholder ?? 'Select ${field.displayLabel}',
              border: const OutlineInputBorder(),
              filled: field.readOnly,
              fillColor: field.readOnly ? Colors.grey[200] : null,
            ),
        options: options
            .map((opt) => FormBuilderFieldOption(value: opt, child: Text(opt)))
            .toList(),
        validator: field.reqd
            ? (value) {
                if (value == null || value.isEmpty) {
                  return '${field.displayLabel} is required';
                }
                return null;
              }
            : null,
        onChanged: (val) => onChanged?.call(_listToValue(val)),
      );
    }

    final initialValueStr = value?.toString() ?? field.defaultValue;
    String? validInitialValue;
    if (initialValueStr != null && initialValueStr.isNotEmpty) {
      if (options.contains(initialValueStr)) {
        validInitialValue = initialValueStr;
      } else {
        validInitialValue = null;
      }
    }

    // Auto-select when exactly one option and no valid selection
    if (options.length == 1 &&
        (validInitialValue == null || validInitialValue.isEmpty)) {
      validInitialValue = options.first;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onChanged?.call(options.first);
      });
    }

    return FormBuilderDropdown<String>(
      key: ValueKey('select_${field.fieldname}_${options.length}'),
      name: field.fieldname ?? '',
      initialValue: validInitialValue,
      enabled: enabled && !field.readOnly,
      decoration:
          style?.decoration ??
          InputDecoration(
            hintText: field.placeholder ?? 'Select ${field.displayLabel}',
            border: const OutlineInputBorder(),
            filled: field.readOnly,
            fillColor: field.readOnly ? Colors.grey[200] : null,
          ),
      items: options.map((option) {
        return DropdownMenuItem<String>(value: option, child: Text(option));
      }).toList(),
      validator: field.reqd
          ? (value) {
              if (value == null || value.toString().isEmpty) {
                return '${field.displayLabel} is required';
              }
              return null;
            }
          : null,
      onChanged: (val) => onChanged?.call(val),
    );
  }
}
