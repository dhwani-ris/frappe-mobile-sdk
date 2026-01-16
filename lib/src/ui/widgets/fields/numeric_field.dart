import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';

/// Widget for numeric field types (Int, Float, Currency, Percent)
class NumericField extends BaseField {
  const NumericField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    final isInt = field.fieldtype == 'Int';
    final isCurrency = field.fieldtype == 'Currency';
    final isPercent = field.fieldtype == 'Percent';

    return FormBuilderTextField(
      key: ValueKey('${field.fieldname}_${value?.toString() ?? field.defaultValue ?? ''}'),
      name: field.fieldname ?? '',
      initialValue: value?.toString() ?? field.defaultValue ?? '',
      enabled: enabled && !field.readOnly,
      keyboardType: TextInputType.numberWithOptions(decimal: !isInt),
      decoration: style?.decoration ?? InputDecoration(
        hintText: field.placeholder,
        border: const OutlineInputBorder(),
        filled: field.readOnly,
        fillColor: field.readOnly ? Colors.grey[200] : null,
        prefixText: isCurrency ? '₹ ' : null,
        suffixText: isPercent ? '%' : null,
      ),
      validator: field.reqd
          ? (value) {
              if (value == null || value.toString().isEmpty) {
                return '${field.displayLabel} is required';
              }
              final numValue = isInt
                  ? int.tryParse(value)
                  : double.tryParse(value);
              if (numValue == null) {
                return 'Please enter a valid number';
              }
              return null;
            }
          : null,
      onChanged: (val) {
        if (val != null && val.isNotEmpty) {
          final numValue = isInt
              ? int.tryParse(val)
              : double.tryParse(val);
          onChanged?.call(numValue);
        } else {
          onChanged?.call(null);
        }
      },
    );
  }
}
