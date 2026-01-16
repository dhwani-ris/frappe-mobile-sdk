import 'package:floor/floor.dart';

/// Entity for caching link field options (documents from linked DocTypes)
@Entity(tableName: 'link_options')
class LinkOptionEntity {
  @PrimaryKey(autoGenerate: true)
  final int? id;

  /// The DocType name (e.g., "State", "District")
  @Index(value: ['doctype'])
  final String doctype;

  /// Document name/ID
  final String name;

  /// Display label (usually name or title field)
  final String? label;

  /// Additional data for the document (stored as JSON string)
  final String? dataJson;

  /// Last updated timestamp (milliseconds since epoch)
  @Index(value: ['lastUpdated'])
  final int lastUpdated;

  LinkOptionEntity({
    this.id,
    required this.doctype,
    required this.name,
    this.label,
    this.dataJson,
    required this.lastUpdated,
  });
}
