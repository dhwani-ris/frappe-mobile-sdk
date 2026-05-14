import '../utils/sql_row_utils.dart';

enum AttachmentState { pending, uploading, done, failed }

extension AttachmentStateHelpers on AttachmentState {
  String get wireName => name;
  static AttachmentState parse(String raw) {
    final value = parseEnumByName(AttachmentState.values, raw);
    if (value == null) throw ArgumentError.value(raw, 'attachment_state');
    return value;
  }
}

class PendingAttachment {
  final int id;
  final String parentUuid;
  final String parentDoctype;
  final String parentFieldname;
  final String topParentUuid;
  final String topParentDoctype;
  final String localPath;
  final String? fileName;
  final String? mimeType;
  final bool isPrivate;
  final int? sizeBytes;
  final AttachmentState state;
  final int retryCount;
  final DateTime? lastAttemptAt;
  final String? errorMessage;
  final String? serverFileName;
  final String? serverFileUrl;
  final DateTime createdAt;

  PendingAttachment({
    required this.id,
    required this.parentUuid,
    required this.parentDoctype,
    required this.parentFieldname,
    required this.topParentUuid,
    required this.topParentDoctype,
    required this.localPath,
    this.fileName,
    this.mimeType,
    required this.isPrivate,
    this.sizeBytes,
    required this.state,
    required this.retryCount,
    this.lastAttemptAt,
    this.errorMessage,
    this.serverFileName,
    this.serverFileUrl,
    required this.createdAt,
  });

  factory PendingAttachment.fromMap(Map<String, Object?> row) {
    return PendingAttachment(
      id: row['id'] as int,
      parentUuid: row['parent_uuid'] as String,
      parentDoctype: row['parent_doctype'] as String,
      parentFieldname: row['parent_fieldname'] as String,
      topParentUuid: row['top_parent_uuid'] as String,
      topParentDoctype: row['top_parent_doctype'] as String,
      localPath: row['local_path'] as String,
      fileName: row['file_name'] as String?,
      mimeType: row['mime_type'] as String?,
      isPrivate: (row['is_private'] as int? ?? 1) == 1,
      sizeBytes: row['size_bytes'] as int?,
      state: AttachmentStateHelpers.parse(row['state'] as String),
      retryCount: retryCountFrom(row),
      lastAttemptAt: lastAttemptAtFrom(row),
      errorMessage: row['error_message'] as String?,
      serverFileName: row['server_file_name'] as String?,
      serverFileUrl: row['server_file_url'] as String?,
      createdAt: utcMillisFrom(row, 'created_at'),
    );
  }
}
