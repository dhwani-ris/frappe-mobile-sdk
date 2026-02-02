import 'dart:io';
import 'package:flutter/material.dart';
import '../../../models/doc_field.dart';
import '../../../constants/field_types.dart';
import '../../../services/link_option_service.dart';
import 'base_field.dart';
import 'data_field.dart';
import 'text_field.dart';
import 'select_field.dart';
import 'date_field.dart';
import 'datetime_field.dart';
import 'time_field.dart';
import 'duration_field.dart';
import 'check_field.dart';
import 'numeric_field.dart';
import 'link_field.dart';
import 'phone_field.dart';
import 'password_field.dart';
import 'rating_field.dart';
import 'read_only_field.dart';
import 'attach_field.dart';
import 'image_field.dart';

/// Factory class to create appropriate field widget based on field type
///
/// Extend this class to customize field creation behavior.
/// Example:
/// ```dart
/// class MyCustomFieldFactory extends FieldFactory {
///   @override
///   BaseField? createField({...}) {
///     // Custom logic here
///     return super.createField(...);
///   }
/// }
/// ```
class FieldFactory {
  LinkOptionService? linkOptionService;
  FieldStyle? defaultStyle;

  FieldFactory({this.linkOptionService, this.defaultStyle});

  /// Create a field widget based on field type
  ///
  /// Override this method to customize field creation.
  BaseField? createField({
    required DocField field,
    dynamic value,
    ValueChanged<dynamic>? onChanged,
    bool enabled = true,
    List<String>? linkOptions,
    Map<String, dynamic>? formData,
    FieldStyle? style,
    Future<String?> Function(File file)? uploadFile,
    String? fileUrlBase,
  }) {
    if (field.hidden) {
      return null;
    }

    final fieldStyle = style ?? defaultStyle;

    switch (field.fieldtype) {
      case FieldTypes.data:
        return DataField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.phone:
        return PhoneField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.text:
      case FieldTypes.longText:
      case FieldTypes.smallText:
        return TextFieldWidget(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.select:
      case 'Table MultiSelect':
      case 'Multi Select':
        return SelectField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.date:
        return DateField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.datetime:
        return DatetimeField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.time:
        return TimeField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.check:
        return CheckField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.float:
      case FieldTypes.currency:
      case FieldTypes.int:
      case FieldTypes.percent:
        return NumericField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.link:
        return LinkField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          linkOptionService: linkOptionService,
          options: linkOptions,
          formData: formData,
          style: fieldStyle,
        );

      case 'Duration':
        return DurationField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case 'Password':
        return PasswordField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case 'Rating':
        return RatingField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case 'Read Only':
        return ReadOnlyField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.attach:
        return AttachField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
          uploadFile: uploadFile,
        );

      case FieldTypes.attachImage:
      case FieldTypes.image:
        return ImageField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
          uploadFile: uploadFile,
          fileUrlBase: fileUrlBase,
        );

      default:
        // For unsupported field types, show a read-only text field with actual value
        // Don't show "Unsupported field type" message as it gets sent to server
        return DataField(
          field: field,
          value: value?.toString() ?? field.defaultValue ?? '',
          onChanged: null,
          enabled: false,
        );
    }
  }
}
