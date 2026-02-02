import 'package:floor/floor.dart';

/// Entity for storing DocType metadata
///
/// Uses generic storage - no table per Doctype
@Entity(tableName: 'doctype_meta')
class DoctypeMetaEntity {
  @PrimaryKey()
  final String doctype;

  /// Last modified timestamp from server
  final String? modified;

  /// Full metadata JSON stored as text
  final String metaJson;

  DoctypeMetaEntity({
    required this.doctype,
    this.modified,
    required this.metaJson,
  });
}
