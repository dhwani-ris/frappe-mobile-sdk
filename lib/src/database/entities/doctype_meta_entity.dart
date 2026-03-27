/// Entity for storing DocType metadata
///
/// Uses generic storage - no table per Doctype
class DoctypeMetaEntity {
  final String doctype;

  /// Last modified timestamp from server metadata
  final String? modified;

  /// Server modified timestamp from mobile_form_names (login response)
  /// Used to determine if doctype meta needs resync
  final String? serverModifiedAt;

  /// Whether this doctype is a mobile form (from login response)
  final bool isMobileForm;

  /// Full metadata JSON stored as text
  final String metaJson;

  /// Group name for organizing doctypes on home screen
  final String? groupName;

  /// Sort order within the group
  final int? sortOrder;

  DoctypeMetaEntity({
    required this.doctype,
    this.modified,
    this.serverModifiedAt,
    this.isMobileForm = false,
    required this.metaJson,
    this.groupName,
    this.sortOrder,
  });

  /// Convert from database map
  factory DoctypeMetaEntity.fromDb(Map<String, dynamic> map) {
    return DoctypeMetaEntity(
      doctype: map['doctype'] as String,
      modified: map['modified'] as String?,
      serverModifiedAt: map['serverModifiedAt'] as String?,
      isMobileForm: (map['isMobileForm'] as int? ?? 0) == 1,
      metaJson: map['metaJson'] as String,
      groupName: map['groupName'] as String?,
      sortOrder: map['sortOrder'] as int?,
    );
  }

  /// Convert to database map
  Map<String, dynamic> toDb() {
    return {
      'doctype': doctype,
      'modified': modified,
      'serverModifiedAt': serverModifiedAt,
      'isMobileForm': isMobileForm ? 1 : 0,
      'metaJson': metaJson,
      'groupName': groupName,
      'sortOrder': sortOrder,
    };
  }
}
