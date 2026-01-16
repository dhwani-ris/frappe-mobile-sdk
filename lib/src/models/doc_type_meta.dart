import 'package:json_annotation/json_annotation.dart';
import 'doc_field.dart';

part 'doc_type_meta.g.dart';

/// Represents Frappe DocType metadata
@JsonSerializable()
class DocTypeMeta {
  final String name;
  final String? label;
  final List<DocField> fields;
  final bool isTable;
  final Map<String, dynamic>? metaData;

  DocTypeMeta({
    required this.name,
    this.label,
    required this.fields,
    this.isTable = false,
    this.metaData,
  });

  factory DocTypeMeta.fromJson(Map<String, dynamic> json) {
    final fieldsJson = json['fields'] as List<dynamic>? ?? [];
    final fields = fieldsJson
        .map((field) {
          try {
            return DocField.fromJson(field as Map<String, dynamic>);
          } catch (e) {
            print('Error parsing field: $field, error: $e');
            // Return a basic field to avoid crashing
            return DocField(
              fieldname: field['fieldname'] as String?,
              fieldtype: field['fieldtype'] as String? ?? 'Data',
            );
          }
        })
        .toList();

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

    return DocTypeMeta(
      name: json['name'] as String? ?? json['doctype'] as String? ?? '',
      label: json['label'] as String?,
      fields: fields,
      isTable: isTableValue,
      metaData: json,
    );
  }

  Map<String, dynamic> toJson() => _$DocTypeMetaToJson(this);

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
        .where((f) => f.inListView && f.fieldname != null && f.fieldname!.isNotEmpty)
        .toList()
      ..sort((a, b) => (a.idx ?? 0).compareTo(b.idx ?? 0));
  }

  /// Get all layout fields
  List<DocField> get layoutFields {
    return fields.where((f) => f.isLayoutField).toList();
  }
}
