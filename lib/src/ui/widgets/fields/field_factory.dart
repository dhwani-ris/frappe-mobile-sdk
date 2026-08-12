import 'dart:io';

import 'package:flutter/material.dart';

import '../../../constants/field_types.dart';
import '../../../models/doc_field.dart';
import '../../../models/doc_type_meta.dart';
import '../../../models/link_filter_result.dart';
import '../../../services/link_option_service.dart';
import '../../../services/link_field_coordinator.dart';
import 'attach_field.dart';
import 'base_field.dart';
import 'button_field.dart';
import 'check_field.dart';
import 'child_table_field.dart';
import 'data_field.dart';
import 'date_field.dart';
import 'datetime_field.dart';
import 'duration_field.dart';
import 'geolocation_field.dart';
import 'html_field.dart';
import 'image_field.dart';
import 'link_field.dart';
import 'numeric_field.dart';
import 'password_field.dart';
import 'phone_field.dart';
import 'rating_field.dart';
import 'read_only_field.dart';
import 'select_field.dart';
import 'table_multi_select_field.dart';
import 'text_field.dart';
import 'time_field.dart';

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
  LinkFieldCoordinator? linkFieldCoordinator;
  FieldStyle? defaultStyle;

  /// When false, drop the length cap on `Data` fields entirely — Frappe stores
  /// **Single** doctypes as `mediumtext` and exempts them from the cap
  /// regardless of any explicit `DocField.length`. Default true (cap), matching
  /// Frappe's non-Single behaviour, where the cap is `DocField.length` when set
  /// and the implicit `varchar(140)` when not.
  ///
  /// Note the asymmetry, which is deliberate and matches the server: `false`
  /// ignores an explicit `length` rather than honouring it. An earlier version
  /// of this doc said only the *implicit* cap was skipped, which contradicted
  /// the implementation in `data_field.dart`.
  ///
  /// Carried as instance state rather than a [createField] parameter ON PURPOSE:
  /// `createField` is documented as overridable, and Dart requires an override
  /// to redeclare every named parameter of the method it overrides. Adding one
  /// here would break every existing subclass at compile time — a default value
  /// does NOT help, because a caller holding a `FieldFactory` reference may
  /// still pass the argument explicitly. Same rationale as [errorTextResolver].
  bool capDataLength = true;

  /// Supplies the inline error for a field, by fieldname. Used for child-table
  /// fieldtypes (`Table` / `Table MultiSelect`), which are NOT
  /// `FormBuilderField`s — so `FormBuilderState.invalidate()` is a silent no-op
  /// for them and they must render their own error.
  ///
  /// Instance state rather than a [createField] parameter for the
  /// subclass-compatibility reason documented on [capDataLength].
  String? Function(String fieldname)? errorTextResolver;

  /// Inline error for [field], or null when none applies.
  String? _errorTextFor(DocField field) {
    final fn = field.fieldname;
    if (fn == null || fn.isEmpty) return null;
    return errorTextResolver?.call(fn);
  }

  FieldFactory({
    this.linkOptionService,
    this.linkFieldCoordinator,
    this.defaultStyle,
  });

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
    Map<String, dynamic>? parentFormData,
    LinkFilterBuilder? Function(String doctype, String fieldname)?
    getLinkFilterBuilder,
    ValueChanged<bool>? onIsLocalChanged,
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
          capLength: capDataLength,
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
      case 'Multi Select':
        return SelectField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
        );

      case 'Table MultiSelect':
        if (getMeta == null) return null;
        final tmsRows = value is List ? List<dynamic>.from(value) : <dynamic>[];
        return TableMultiSelectFieldBase(
          field: field,
          rows: tmsRows,
          onChanged: onChanged,
          enabled: enabled,
          getMeta: getMeta,
          linkOptionService: linkOptionService,
          formData: formData ?? const {},
          parentFormData: parentFormData ?? const {},
          getLinkFilterBuilder: getLinkFilterBuilder,
          style: fieldStyle,
          // Not a FormBuilderField → `invalidate()` cannot reach it, so the
          // form builder's mandatory sweep routes its required-empty message
          // here (same channel as 'Table' below).
          errorText: _errorTextFor(field),
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
          linkFieldCoordinator: linkFieldCoordinator,
          options: linkOptions,
          formData: formData,
          parentFormData: parentFormData ?? const {},
          getLinkFilterBuilder: getLinkFilterBuilder,
          style: fieldStyle,
          onIsLocalChanged: onIsLocalChanged,
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
          errorText: _errorTextFor(field),
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
          fileUrlBase: fileUrlBase,
          imageHeaders: imageHeaders,
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

      case FieldTypes.html:
        return HtmlField(
          field: field,
          value: value,
          enabled: enabled,
          style: fieldStyle,
        );

      case FieldTypes.geolocation:
        return GeolocationField(
          field: field,
          value: value,
          onChanged: onChanged,
          enabled: enabled,
          style: fieldStyle,
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
  final String? errorText;

  const _TableFieldBase({
    required super.field,
    required this.value,
    required super.onChanged,
    required super.enabled,
    required this.getMeta,
    required this.formBuilder,
    super.style,
    this.errorText,
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
      errorText: errorText,
    );
  }

  @override
  Widget buildField(BuildContext context) => const SizedBox.shrink();
}
