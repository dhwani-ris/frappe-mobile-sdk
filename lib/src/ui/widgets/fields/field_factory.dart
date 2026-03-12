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
import 'button_field.dart';
import 'child_table_field.dart';
import '../../../models/doc_type_meta.dart';

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
    Map<String, String>? imageHeaders,
    Future<DocTypeMeta> Function(String doctype)? getMeta,
    ChildTableFormBuilder? childTableFormBuilder,
    Future<void> Function(DocField field, Map<String, dynamic> formData)?
    onButtonPressed,
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

      case 'Table':
        if (getMeta == null || childTableFormBuilder == null) return null;
        final listValue = value is List
            ? List<dynamic>.from(value)
            : <dynamic>[];
        return _TableFieldBase(
          field: field,
          value: listValue,
          onChanged: onChanged,
          enabled: enabled,
          getMeta: getMeta,
          formBuilder: childTableFormBuilder,
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
          imageHeaders: imageHeaders,
        );

      case FieldTypes.button:
        return ButtonField(
          field: field,
          enabled: enabled,
          style: fieldStyle,
          onButtonPressed: onButtonPressed,
          formData: formData ?? const {},
        );

      default:
        // For unsupported field types, show a read-only text field with actual value
        return DataField(
          field: field,
          value: value?.toString() ?? field.defaultValue ?? '',
          onChanged: null,
          enabled: false,
        );
    }
  }
}

/// BaseField wrapper for Table/child table so it fits the createField API.
class _TableFieldBase extends BaseField {
  @override
  // ignore: overridden_fields - intentional narrower type for table rows
  final List<dynamic> value;
  final Future<DocTypeMeta> Function(String doctype) getMeta;
  final ChildTableFormBuilder formBuilder;

  const _TableFieldBase({
    required super.field,
    required this.value,
    required super.onChanged,
    required super.enabled,
    required this.getMeta,
    required this.formBuilder,
    super.style,
  });

  @override
  Widget build(BuildContext context) {
    if (field.hidden) return const SizedBox.shrink();
    return ChildTableField(
      field: field,
      value: value,
      onChanged: onChanged != null
          ? (List<dynamic> v) => onChanged!.call(v)
          : null,
      enabled: enabled,
      getMeta: getMeta,
      formBuilder: formBuilder,
    );
  }

  @override
  Widget buildField(BuildContext context) => const SizedBox.shrink();
}
