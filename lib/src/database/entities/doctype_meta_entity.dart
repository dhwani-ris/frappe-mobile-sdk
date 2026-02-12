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

  DoctypeMetaEntity({
    required this.doctype,
    this.modified,
    this.serverModifiedAt,
    this.isMobileForm = false,
    required this.metaJson,
  });

  /// Convert from database map
  factory DoctypeMetaEntity.fromDb(Map<String, dynamic> map) {
    return DoctypeMetaEntity(
      doctype: map['doctype'] as String,
      modified: map['modified'] as String?,
      serverModifiedAt: map['serverModifiedAt'] as String?,
      isMobileForm: (map['isMobileForm'] as int? ?? 0) == 1,
      metaJson: map['metaJson'] as String,
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
    };
  }
}
