/// Entity for storing documents
///
/// Uses generic storage - no table per Doctype
/// All documents stored in single table with JSON data
class DocumentEntity {
  final String localId;

  /// DocType name
  final String doctype;

  /// Server document name (null for new documents)
  final String? serverId;

  /// Document data stored as JSON string
  final String dataJson;

  /// Sync status: dirty | clean | deleted
  final String status;

  /// Last modified timestamp (milliseconds since epoch)
  final int modified;

  DocumentEntity({
    required this.localId,
    required this.doctype,
    this.serverId,
    required this.dataJson,
    required this.status,
    required this.modified,
  });

  /// Convert from database map
  factory DocumentEntity.fromDb(Map<String, dynamic> map) {
    return DocumentEntity(
      localId: map['localId'] as String,
      doctype: map['doctype'] as String,
      serverId: map['serverId'] as String?,
      dataJson: map['dataJson'] as String,
      status: map['status'] as String,
      modified: map['modified'] as int,
    );
  }

  /// Convert to database map
  Map<String, dynamic> toDb() {
    return {
      'localId': localId,
      'doctype': doctype,
      'serverId': serverId,
      'dataJson': dataJson,
      'status': status,
      'modified': modified,
    };
  }
}
