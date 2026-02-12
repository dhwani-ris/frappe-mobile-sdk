/// Entity for caching link field options (documents from linked DocTypes)
class LinkOptionEntity {
  final int? id;

  /// The DocType name (e.g., "State", "District")
  final String doctype;

  /// Document name/ID
  final String name;

  /// Display label (usually name or title field)
  final String? label;

  /// Additional data for the document (stored as JSON string)
  final String? dataJson;

  /// Last updated timestamp (milliseconds since epoch)
  final int lastUpdated;

  LinkOptionEntity({
    this.id,
    required this.doctype,
    required this.name,
    this.label,
    this.dataJson,
    required this.lastUpdated,
  });

  /// Convert from database map
  factory LinkOptionEntity.fromDb(Map<String, dynamic> map) {
    return LinkOptionEntity(
      id: map['id'] as int?,
      doctype: map['doctype'] as String,
      name: map['name'] as String,
      label: map['label'] as String?,
      dataJson: map['dataJson'] as String?,
      lastUpdated: map['lastUpdated'] as int,
    );
  }

  /// Convert to database map
  Map<String, dynamic> toDb() {
    final map = <String, dynamic>{
      'doctype': doctype,
      'name': name,
      'label': label,
      'dataJson': dataJson,
      'lastUpdated': lastUpdated,
    };
    if (id != null) {
      map['id'] = id;
    }
    return map;
  }
}
