import 'dart:convert';

import '../utils/frappe_json_utils.dart' as frappe_json;

/// Represents a Frappe DocField (field definition in metadata)
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
  final String? fetchFrom;
  final String? section;
  final String? defaultValue;
  final String? description;
  final String? placeholder;
  final int? precision;
  final int? length;
  final int? idx;
  final bool inListView;
  final bool allowMultiple;

  /// Frappe `search_index=1` flag — indicates the field should be indexed
  /// for search. Used by the offline-first SDK's index policy.
  final bool searchIndex;

  /// Frappe `is_virtual=1` flag — the field is computed at runtime (property
  /// setter / controller) and has NO database column, whatever its fieldtype.
  /// Selecting it would send an unknown column to the server, so callers that
  /// build column lists must skip it.
  final bool isVirtual;

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
    this.fetchFrom,
    this.section,
    this.defaultValue,
    this.description,
    this.placeholder,
    this.precision,
    this.length,
    this.idx,
    this.inListView = false,
    this.allowMultiple = false,
    this.searchIndex = false,
    this.isVirtual = false,
  });

  factory DocField.fromJson(Map<String, dynamic> json) {
    // Frappe's JSON encodes booleans inconsistently — see frappe_json_utils.
    bool parseBool(dynamic v, {bool defaultValue = false}) =>
        frappe_json.parseBool(v, defaultValue: defaultValue);

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
      fetchFrom: json['fetch_from'] as String? ?? json['fetchFrom'] as String?,
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
      searchIndex:
          parseBool(json['search_index']) || parseBool(json['searchIndex']),
      isVirtual: parseBool(json['is_virtual']) || parseBool(json['isVirtual']),
    );
  }

  static bool _isMultiSelectFieldType(String? fieldtype) {
    if (fieldtype == null) return false;
    final t = fieldtype.toLowerCase().replaceAll(' ', '');
    return t == 'tablemultiselect' || t == 'multiselect';
  }

  Map<String, dynamic> toJson() {
    return {
      if (fieldname != null) 'fieldname': fieldname,
      'fieldtype': fieldtype,
      if (label != null) 'label': label,
      'reqd': reqd ? 1 : 0,
      'read_only': readOnly ? 1 : 0,
      'hidden': hidden ? 1 : 0,
      if (options != null) 'options': options,
      if (dependsOn != null) 'depends_on': dependsOn,
      if (mandatoryDependsOn != null)
        'mandatory_depends_on': mandatoryDependsOn,
      if (readOnlyDependsOn != null) 'read_only_depends_on': readOnlyDependsOn,
      if (linkFilters != null) 'link_filters': linkFilters,
      if (fetchFrom != null) 'fetch_from': fetchFrom,
      if (section != null) 'section': section,
      if (defaultValue != null) 'default': defaultValue,
      if (description != null) 'description': description,
      if (placeholder != null) 'placeholder': placeholder,
      if (precision != null) 'precision': precision,
      if (length != null) 'length': length,
      if (idx != null) 'idx': idx,
      'in_list_view': inListView ? 1 : 0,
      'allow_multiple': allowMultiple ? 1 : 0,
      'search_index': searchIndex ? 1 : 0,
      // Always emitted (like `search_index`): DocTypeMeta.toJson() is what
      // MetaService persists into the local meta cache, so omitting the key
      // would silently drop the flag on the next cold start and re-emit the
      // virtual column in a ['*'] expansion.
      'is_virtual': isVirtual ? 1 : 0,
    };
  }

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

  /// Zero-width / invisible characters stripped when probing whether a label
  /// carries any real text. Hoisted to a `static final` because [displayLabel]
  /// runs on widget build paths and recompiling the pattern per call is pure
  /// allocation churn.
  static final RegExp _zeroWidthPattern = RegExp(
    '[\\u200B\\u200C\\u200D\\uFEFF]',
  );

  /// Get display label.
  ///
  /// A label that is null, blank, or made only of zero-width/invisible
  /// characters (hosts blank labels to `'​'` to suppress duplicate
  /// rendering) falls back to a humanized fieldname — otherwise validation
  /// messages degrade to a bare "is required".
  String get displayLabel {
    final l = label;
    if (l != null && l.replaceAll(_zeroWidthPattern, '').trim().isNotEmpty) {
      return l;
    }
    final f = fieldname;
    if (f == null || f.isEmpty) return '';
    return f
        .split('_')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }
}
