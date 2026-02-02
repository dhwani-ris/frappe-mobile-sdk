import 'package:floor/floor.dart';

/// Entity for storing documents
///
/// Uses generic storage - no table per Doctype
/// All documents stored in single table with JSON data
@Entity(tableName: 'documents')
class DocumentEntity {
  @PrimaryKey()
  final String localId;

  /// DocType name
  @Index(value: ['doctype'])
  final String doctype;

  /// Server document name (null for new documents)
  final String? serverId;

  /// Document data stored as JSON string
  final String dataJson;

  /// Sync status: dirty | clean | deleted
  @Index(value: ['status'])
  final String status;

  /// Last modified timestamp (milliseconds since epoch)
  @Index(value: ['modified'])
  final int modified;

  DocumentEntity({
    required this.localId,
    required this.doctype,
    this.serverId,
    required this.dataJson,
    required this.status,
    required this.modified,
  });
}
