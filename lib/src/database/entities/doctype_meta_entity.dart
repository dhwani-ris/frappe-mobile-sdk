import 'package:floor/floor.dart';

/// Entity for storing DocType metadata
///
/// Uses generic storage - no table per Doctype
@Entity(tableName: 'doctype_meta')
class DoctypeMetaEntity {
  @PrimaryKey()
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
}
