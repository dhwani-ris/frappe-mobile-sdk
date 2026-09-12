import 'package:flutter/foundation.dart';

import '../utils/frappe_json_utils.dart';
import 'doc_field.dart';

/// Represents Frappe DocType metadata
class DocTypeMeta {
  final String name;
  final String? label;
  final List<DocField> fields;
  final bool isTable;
  final Map<String, dynamic>? metaData;

  /// Field to show as main title in list view (from Frappe title_field)
  final String? titleField;

  /// Default sort field for list view (from Frappe sort_field)
  final String? sortField;

  /// Default sort order: 'asc' or 'desc' (from Frappe sort_order)
  final String? sortOrder;

  /// Comma-separated list of fieldnames used for search in list view
  /// (from Frappe `search_fields`). May be null.
  final List<String>? searchFields;

  /// Frappe's naming rule. Examples:
  /// - `field:mobile_uuid` (used by L1 idempotency — name = mobile_uuid)
  /// - `naming_series:` (used with naming_series field)
  /// - `Prompt`, `hash`, `format:...` etc.
  /// Null when not configured. See spec §5.7.
  final String? autoname;

  /// True if this doctype supports submit/cancel workflow (Frappe is_submittable)
  ///
  /// Uses [parseBool] so Frappe's inconsistent boolean encodings (int `1`,
  /// bool `true`, or the string `"1"`) all resolve correctly.
  bool get isSubmittable => parseBool(metaData?['is_submittable']);

  /// True if this doctype's document titles should be translated when shown
  /// (Frappe `translated_doctype`). Matches Frappe web, which translates a
  /// Link / Table MultiSelect field's option titles only when the field's
  /// *target* doctype has this flag set (see `link.js`, `formatters.js`).
  /// Uses [parseBool] so Frappe's inconsistent boolean encodings (int `1`,
  /// bool `true`, or the string `"1"`) all resolve correctly.
  bool get translatedDoctype => parseBool(metaData?['translated_doctype']);

  /// True for a Frappe **Single** doctype (`issingle`). Single doctypes store
  /// their values as `mediumtext`, so Frappe exempts them from the implicit
  /// `Data` varchar(140) length cap in both its web control and server
  /// `_validate_length`. Used to skip the on-device 140-char cap for Singles.
  /// Uses [parseBool] for Frappe's int/bool/string boolean encodings.
  bool get isSingle => parseBool(metaData?['issingle']);

  DocTypeMeta({
    required this.name,
    this.label,
    required this.fields,
    this.isTable = false,
    this.metaData,
    this.titleField,
    this.sortField,
    this.sortOrder,
    this.searchFields,
    this.autoname,
  });

  factory DocTypeMeta.fromJson(Map<String, dynamic> json) {
    final fieldsJson = json['fields'] as List<dynamic>? ?? [];
    final fields = fieldsJson.map((field) {
      try {
        return DocField.fromJson(field as Map<String, dynamic>);
      } catch (e, st) {
        debugPrint(
          'DocTypeMeta.fromJson: DocField parse failed (${field is Map ? field['fieldname'] : 'unknown'}) — $e\n$st',
        );
        // Keep the raw payload even on the fallback: several app screens read
        // `meta.toJson()['fields']` and expect full-fidelity maps, and toJson()
        // replays unmodelled keys from `rawData`. Without this a field that
        // fails typed parsing would serialise to a two-key stub.
        return DocField(
          fieldname: field['fieldname'] as String?,
          fieldtype: field['fieldtype'] as String? ?? 'Data',
          rawData: field is Map<String, dynamic> ? field : null,
        );
      }
    }).toList();

    // Handle isTable - can be int (0/1) or bool. See frappe_json_utils.
    final isTableValue = parseBool(json['istable'] ?? json['isTable']);

    final titleField = json['title_field'] as String?;
    final sortField = json['sort_field'] as String?;
    final sortOrder = json['sort_order'] as String?;

    final searchFieldsRaw = json['search_fields'] as String?;
    final searchFields = searchFieldsRaw == null || searchFieldsRaw.isEmpty
        ? null
        : searchFieldsRaw
              .split(',')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();

    final autoname = json['autoname'] as String?;

    return DocTypeMeta(
      name: json['name'] as String? ?? json['doctype'] as String? ?? '',
      label: json['label'] as String?,
      fields: fields,
      isTable: isTableValue,
      metaData: json,
      titleField: titleField?.isNotEmpty == true ? titleField : null,
      sortField: sortField?.isNotEmpty == true ? sortField : null,
      sortOrder: sortOrder?.toLowerCase() == 'desc'
          ? 'desc'
          : (sortOrder?.isNotEmpty == true ? 'asc' : null),
      searchFields: searchFields,
      autoname: autoname?.isNotEmpty == true ? autoname : null,
    );
  }

  Map<String, dynamic> toJson() {
    // `metaData` is the ENTIRE raw payload this meta was parsed from (see
    // fromJson), so it carries its own `fields` list. It MUST be spread FIRST:
    // a later key wins in a Dart map literal, so spreading it last made the raw
    // payload overwrite `fields` below, and every edit to the typed `fields`
    // list was silently discarded by the next
    // `DocTypeMeta.fromJson(meta.toJson())` round-trip — which is exactly what
    // the render path does before drawing a form. Client scripts that strip or
    // reorder fields therefore appeared to work and changed nothing on screen.
    //
    // `fields` and the `isTable` alias are dropped from the passthrough so the
    // typed values below are authoritative. Everything else in the raw payload
    // (permissions, issingle, is_submittable, __workflow_docs, …) still flows
    // through untouched, and the guarded keys below intentionally fall back to
    // the raw value when the typed one is null.
    final passthrough = <String, dynamic>{};
    final raw = metaData;
    if (raw != null) {
      for (final entry in raw.entries) {
        if (entry.key != 'fields' && entry.key != 'isTable') {
          passthrough[entry.key] = entry.value;
        }
      }
    }

    return {
      ...passthrough,
      'name': name,
      if (label != null) 'label': label,
      'fields': fields.map((f) => f.toJson()).toList(),
      'istable': isTable ? 1 : 0,
      if (titleField != null) 'title_field': titleField,
      if (sortField != null) 'sort_field': sortField,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (searchFields != null && searchFields!.isNotEmpty)
        'search_fields': searchFields!.join(','),
      if (autoname != null) 'autoname': autoname,
    };
  }

  /// Returns true if current user (by [userRoles]) is allowed [action] at permlevel 0.
  ///
  /// [action] is one of: 'read', 'create', 'write', 'delete', 'submit'.
  bool hasPermission(String action, {List<String>? userRoles}) {
    final meta = metaData;
    if (meta == null) {
      return true;
    }

    final perms =
        meta['permissions'] as List<dynamic>? ??
        meta['__permissions'] as List<dynamic>? ??
        const [];
    if (perms.isEmpty) {
      return true;
    }

    for (final raw in perms) {
      if (raw is! Map<String, dynamic>) continue;
      // Only consider permlevel 0 for now (main document permissions)
      final permLevel = raw['permlevel'] ?? raw['perm_level'] ?? 0;
      if (permLevel is num && permLevel != 0) continue;

      if (!parseBool(raw[action])) continue;

      final role = raw['role']?.toString();
      if (userRoles == null || userRoles.isEmpty) {
        // No user roles provided - treat as allowed when any row grants permission
        return true;
      }
      if (role == null || role.isEmpty || userRoles.contains(role)) {
        return true;
      }
    }

    return false;
  }

  /// Get field by fieldname
  DocField? getField(String fieldname) {
    for (final f in fields) {
      if (f.fieldname == fieldname) return f;
    }
    return null;
  }

  /// Get all data fields (excluding layout fields)
  List<DocField> get dataFields {
    return fields.where((f) => f.isDataField).toList();
  }

  /// Get fields that should be shown in list view
  List<DocField> get listViewFields {
    return fields
        .where(
          (f) => f.inListView && f.fieldname != null && f.fieldname!.isNotEmpty,
        )
        .toList()
      ..sort((a, b) => (a.idx ?? 0).compareTo(b.idx ?? 0));
  }

  /// Get all layout fields
  List<DocField> get layoutFields {
    return fields.where((f) => f.isLayoutField).toList();
  }

  /// True if this DocType has a Frappe workflow attached (from meta [__workflow_docs]).
  bool get hasWorkflow {
    final docs = metaData?['__workflow_docs'];
    return docs is List && docs.isNotEmpty;
  }

  /// Name of the field that stores workflow state (e.g. [workflow_state]).
  /// Non-null only when [hasWorkflow] is true; read from first __workflow_docs entry.
  String? get workflowStateField {
    if (!hasWorkflow) return null;
    final docs = metaData!['__workflow_docs'] as List;
    if (docs.isEmpty) return null;
    final first = docs[0];
    if (first is! Map<String, dynamic>) return null;
    final v = first['workflow_state_field'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Field names that participate in normalized search — title field plus
  /// every entry in `search_fields`. Schema, form-save, and pull-apply all
  /// use this set to decide which TEXT columns get a `__norm` mirror column.
  /// Centralized here so the three writers can't drift apart.
  Set<String> get normFieldNames {
    final out = <String>{};
    if (titleField != null) out.add(titleField!);
    for (final sf in (searchFields ?? const <String>[])) {
      out.add(sf);
    }
    return out;
  }
}
