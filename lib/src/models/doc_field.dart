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
  final String? defaultValue;
  final String? description;
  final String? placeholder;
  final int? precision;
  final int? length;
  final int? idx;
  final bool inListView;

  DocField({
    this.fieldname,
    required this.fieldtype,
    this.label,
    this.reqd = false,
    this.readOnly = false,
    this.hidden = false,
    this.options,
    this.dependsOn,
    this.defaultValue,
    this.description,
    this.placeholder,
    this.precision,
    this.length,
    this.idx,
    this.inListView = false,
  });

  factory DocField.fromJson(Map<String, dynamic> json) {
    // Handle Frappe's JSON format - can be int (0/1) or bool
    bool _parseBool(dynamic value, {bool defaultValue = false}) {
      if (value == null) return defaultValue;
      if (value is bool) return value;
      if (value is int) return value == 1;
      if (value is String) return value == '1' || value.toLowerCase() == 'true';
      return defaultValue;
    }

    int? _parseInt(dynamic value) {
      if (value == null) return null;
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    return DocField(
      fieldname: json['fieldname'] as String?,
      fieldtype: json['fieldtype'] as String? ?? 'Data',
      label: json['label'] as String?,
      reqd: _parseBool(json['reqd']),
      readOnly: _parseBool(json['read_only']) || _parseBool(json['readOnly']),
      hidden: _parseBool(json['hidden']),
      options: json['options'] as String?,
      dependsOn: json['depends_on'] as String? ?? json['dependsOn'] as String?,
      defaultValue: json['default'] as String? ?? json['defaultValue'] as String?,
      description: json['description'] as String?,
      placeholder: json['placeholder'] as String?,
      precision: _parseInt(json['precision']),
      length: _parseInt(json['length']),
      idx: _parseInt(json['idx']),
      inListView: _parseBool(json['in_list_view']) || _parseBool(json['inListView']),
    );
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
