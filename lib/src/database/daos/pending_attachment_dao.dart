import 'package:sqflite/sqflite.dart';
import '../../models/pending_attachment.dart';

class PendingAttachmentDao {
  final DatabaseExecutor _db;

  PendingAttachmentDao(this._db);

  Future<int> enqueue({
    required String parentDoctype,
    required String parentUuid,
    required String parentFieldname,
    required String localPath,
    String? fileName,
    String? mimeType,
    bool isPrivate = true,
    int? sizeBytes,
  }) async {
    return _db.insert('pending_attachments', <String, Object?>{
      'parent_doctype': parentDoctype,
      'parent_uuid': parentUuid,
      'parent_fieldname': parentFieldname,
      'local_path': localPath,
      'file_name': fileName,
      'mime_type': mimeType,
      'is_private': isPrivate ? 1 : 0,
      'size_bytes': sizeBytes,
      'state': AttachmentState.pending.wireName,
      'retry_count': 0,
      'created_at': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
  }

  Future<PendingAttachment?> findById(int id) async {
    final rows = await _db.query(
      'pending_attachments',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PendingAttachment.fromMap(rows.first);
  }

  Future<List<PendingAttachment>> findPendingForParent(
    String parentUuid,
  ) async {
    final rows = await _db.query(
      'pending_attachments',
      where: 'parent_uuid = ? AND state IN (?, ?)',
      whereArgs: [
        parentUuid,
        AttachmentState.pending.wireName,
        AttachmentState.uploading.wireName,
      ],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingAttachment.fromMap).toList();
  }

  Future<void> markUploading(int id) async {
    await _db.update(
      'pending_attachments',
      <String, Object?>{
        'state': AttachmentState.uploading.wireName,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markDone(
    int id, {
    required String serverFileName,
    required String serverFileUrl,
  }) async {
    await _db.update(
      'pending_attachments',
      <String, Object?>{
        'state': AttachmentState.done.wireName,
        'server_file_name': serverFileName,
        'server_file_url': serverFileUrl,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(int id, {required String errorMessage}) async {
    await _db.rawUpdate(
      '''
      UPDATE pending_attachments
        SET state = ?, error_message = ?,
            retry_count = retry_count + 1,
            last_attempt_at = ?
        WHERE id = ?
      ''',
      [
        AttachmentState.failed.wireName,
        errorMessage,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        id,
      ],
    );
  }
}
