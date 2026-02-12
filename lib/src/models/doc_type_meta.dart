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

  DocTypeMeta({
    required this.name,
    this.label,
    required this.fields,
    this.isTable = false,
    this.metaData,
    this.titleField,
    this.sortField,
    this.sortOrder,
  });

  factory DocTypeMeta.fromJson(Map<String, dynamic> json) {
    final fieldsJson = json['fields'] as List<dynamic>? ?? [];
    final fields = fieldsJson.map((field) {
      try {
        return DocField.fromJson(field as Map<String, dynamic>);
      } catch (e) {
        return DocField(
          fieldname: field['fieldname'] as String?,
          fieldtype: field['fieldtype'] as String? ?? 'Data',
        );
      }
    }).toList();

    // Handle isTable - can be int (0/1) or bool
    bool isTableValue = false;
    if (json['istable'] != null) {
      if (json['istable'] is bool) {
        isTableValue = json['istable'] as bool;
      } else if (json['istable'] is int) {
        isTableValue = (json['istable'] as int) == 1;
      }
    } else if (json['isTable'] != null) {
      if (json['isTable'] is bool) {
        isTableValue = json['isTable'] as bool;
      } else if (json['isTable'] is int) {
        isTableValue = (json['isTable'] as int) == 1;
      }
    }

    final titleField = json['title_field'] as String?;
    final sortField = json['sort_field'] as String?;
    final sortOrder = json['sort_order'] as String?;

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
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (label != null) 'label': label,
      'fields': fields.map((f) => f.toJson()).toList(),
      'istable': isTable ? 1 : 0,
      if (metaData != null) ...metaData!,
      if (titleField != null) 'title_field': titleField,
      if (sortField != null) 'sort_field': sortField,
      if (sortOrder != null) 'sort_order': sortOrder,
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

      final flag = raw[action];
      final allowed = flag == 1 || flag == true;
      if (!allowed) continue;

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
    try {
      return fields.firstWhere((f) => f.fieldname == fieldname);
    } catch (e) {
      return null;
    }
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
}
