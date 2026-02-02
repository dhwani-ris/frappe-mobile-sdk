import 'dart:convert';
import 'package:json_annotation/json_annotation.dart';

part 'doc_field.g.dart';

/// Represents a Frappe DocField (field definition in metadata)
@JsonSerializable()
class DocField {
  final String? fieldname;
  final String fieldtype;
  final String? label;
  final bool reqd;
  final bool readOnly;
  final bool hidden;
  final String? options;
  final String? dependsOn;
  final String? mandatoryDependsOn;
  final String? readOnlyDependsOn;
  final String? linkFilters;
  final String? section;
  final String? defaultValue;
  final String? description;
  final String? placeholder;
  final int? precision;
  final int? length;
  final int? idx;
  final bool inListView;
  final bool allowMultiple;

  DocField({
    this.fieldname,
    required this.fieldtype,
    this.label,
    this.reqd = false,
    this.readOnly = false,
    this.hidden = false,
    this.options,
    this.dependsOn,
    this.mandatoryDependsOn,
    this.readOnlyDependsOn,
    this.linkFilters,
    this.section,
    this.defaultValue,
    this.description,
    this.placeholder,
    this.precision,
    this.length,
    this.idx,
    this.inListView = false,
    this.allowMultiple = false,
  });

  factory DocField.fromJson(Map<String, dynamic> json) {
    // Handle Frappe's JSON format - can be int (0/1) or bool
    bool parseBool(dynamic value, {bool defaultValue = false}) {
      if (value == null) return defaultValue;
      if (value is bool) return value;
      if (value is int) return value == 1;
      if (value is String) return value == '1' || value.toLowerCase() == 'true';
      return defaultValue;
    }

    int? parseInt(dynamic value) {
      if (value == null) return null;
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    String? linkFiltersFromJson(dynamic value) {
      if (value == null) return null;
      if (value is String) return value.isEmpty ? null : value;
      if (value is List) return value.isEmpty ? null : jsonEncode(value);
      return null;
    }

    return DocField(
      fieldname: json['fieldname'] as String?,
      fieldtype: json['fieldtype'] as String? ?? 'Data',
      label: json['label'] as String?,
      reqd: parseBool(json['reqd']),
      readOnly: parseBool(json['read_only']) || parseBool(json['readOnly']),
      hidden: parseBool(json['hidden']),
      options: json['options'] as String?,
      dependsOn: json['depends_on'] as String? ?? json['dependsOn'] as String?,
      mandatoryDependsOn:
          json['mandatory_depends_on'] as String? ??
          json['mandatoryDependsOn'] as String?,
      readOnlyDependsOn:
          json['read_only_depends_on'] as String? ??
          json['readOnlyDependsOn'] as String?,
      linkFilters: linkFiltersFromJson(
        json['link_filters'] ?? json['linkFilters'],
      ),
      section: json['section'] as String?,
      defaultValue:
          json['default'] as String? ?? json['defaultValue'] as String?,
      description: json['description'] as String?,
      placeholder: json['placeholder'] as String?,
      precision: parseInt(json['precision']),
      length: parseInt(json['length']),
      idx: parseInt(json['idx']),
      inListView:
          parseBool(json['in_list_view']) || parseBool(json['inListView']),
      allowMultiple:
          parseBool(json['allow_multiple']) ||
          parseBool(json['allowMultiple']) ||
          _isMultiSelectFieldType(json['fieldtype'] as String?),
    );
  }

  static bool _isMultiSelectFieldType(String? fieldtype) {
    if (fieldtype == null) return false;
    final t = fieldtype.toLowerCase().replaceAll(' ', '');
    return t == 'tablemultiselect' || t == 'multiselect';
  }

  Map<String, dynamic> toJson() => _$DocFieldToJson(this);

  /// Check if this is a layout field (Section Break, Column Break, Tab Break)
  bool get isLayoutField {
    return fieldtype == 'Section Break' ||
        fieldtype == 'Column Break' ||
        fieldtype == 'Tab Break';
  }

  /// Check if this is a data field (has a value)
  bool get isDataField {
    return !isLayoutField &&
        fieldtype != 'HTML' &&
        fieldtype != 'Button' &&
        fieldtype != 'Image' &&
        fieldtype != 'Fold' &&
        fieldtype != 'Heading';
  }

  /// Get display label
  String get displayLabel {
    return label ?? fieldname ?? '';
  }
}
