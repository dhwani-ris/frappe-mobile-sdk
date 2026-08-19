import 'package:sqflite/sqflite.dart';
import '../../models/pending_attachment.dart';
import '../../utils/media_store.dart';

class PendingAttachmentDao {
  final DatabaseExecutor _db;

  PendingAttachmentDao(this._db);

  Future<int> enqueue({
    required String parentDoctype,
    required String parentUuid,
    required String parentFieldname,
    required String topParentUuid,
    required String topParentDoctype,
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
      'top_parent_uuid': topParentUuid,
      'top_parent_doctype': topParentDoctype,
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

  /// Rows with work outstanding for [topParentUuid] — everything not yet
  /// `done`. Includes attachments queued against child-row uuids whose
  /// `top_parent_uuid` was set to the parent's uuid at enqueue time.
  ///
  /// Deliberately includes `failed` (retryable) and `rejected` (terminal, but
  /// must still BLOCK the push rather than be silently skipped). Skipping a
  /// non-done row is exactly what let a raw `pending:<id>` marker reach Frappe:
  /// the old query selected only pending/uploading, so once a row left those
  /// states the marker resolved to nothing and was sent verbatim.
  Future<List<PendingAttachment>> findUnresolvedForTopParent(
    String topParentUuid,
  ) async {
    final rows = await _db.query(
      'pending_attachments',
      where: 'top_parent_uuid = ? AND state != ?',
      whereArgs: [topParentUuid, AttachmentState.done.wireName],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingAttachment.fromMap).toList();
  }

  /// Every row for the doc, in any state. Used to build the marker-resolution
  /// map so a marker left behind by an interrupted writeback still resolves
  /// from the already-recorded `server_file_url`.
  Future<List<PendingAttachment>> findAllForTopParent(
    String topParentUuid,
  ) async {
    final rows = await _db.query(
      'pending_attachments',
      where: 'top_parent_uuid = ?',
      whereArgs: [topParentUuid],
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingAttachment.fromMap).toList();
  }

  /// Every `local_path` referenced by a queued attachment, in ANY state.
  ///
  /// State is deliberately not filtered: a `failed` or `rejected` row still
  /// owns its file so the user can retry or replace it, and a `done` row's file
  /// has already left `outbox/`. Anything in this set is off-limits to the
  /// orphan sweep.
  Future<Set<String>> referencedLocalPaths() async {
    final rows = await _db.query(
      'pending_attachments',
      columns: ['local_path'],
    );
    final out = <String>{};
    for (final r in rows) {
      final path = r['local_path'] as String?;
      if (path != null && path.isNotEmpty) out.add(path);
    }
    return out;
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

  /// Persists the uploaded File identifiers WITHOUT transitioning to `done`.
  /// Called immediately after a successful upload so that if the subsequent
  /// [markDone] write fails (or the process is interrupted), a later attempt
  /// reuses the already-uploaded binary instead of re-uploading it and
  /// creating a duplicate File row (PR#36 round-4 H3). The row stays in
  /// `uploading` so it is still picked up by [findUnresolvedForTopParent].
  Future<void> recordUpload(
    int id, {
    required String serverFileName,
    required String serverFileUrl,
  }) async {
    await _db.update(
      'pending_attachments',
      <String, Object?>{
        'server_file_name': serverFileName,
        'server_file_url': serverFileUrl,
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

  /// Removes every attachment row for [topParentUuid], in any state, **and
  /// deletes each row's staged `outbox/` file**.
  ///
  /// Used when the parent doc is deleted, discarded (offline-cancelled INSERT)
  /// or tombstoned, so the uploader doesn't retry against a doc that no longer
  /// exists. Deleting the rows alone would strand the files: nothing else ever
  /// reclaims `outbox/`, and there would no longer be a row pointing at them.
  ///
  /// Deliberately does NOT touch `media_cache` or `cache/`. Cached bytes are
  /// keyed by `file_url` and may be shared with other documents, so their
  /// lifetime is governed by eviction and wipe only — never by the lifecycle
  /// of one document.
  Future<int> deleteForTopParent(String topParentUuid) async {
    final rows = await _db.query(
      'pending_attachments',
      columns: ['local_path'],
      where: 'top_parent_uuid = ?',
      whereArgs: [topParentUuid],
    );
    for (final r in rows) {
      final path = r['local_path'] as String?;
      if (path != null && path.isNotEmpty) {
        await MediaStore.deleteOutboxCopy(path);
      }
    }
    return _db.delete(
      'pending_attachments',
      where: 'top_parent_uuid = ?',
      whereArgs: [topParentUuid],
    );
  }

  /// Terminal rejection — the server will refuse this file every time
  /// (oversized, wrong type, not permitted).
  ///
  /// NEVER auto-retried. Only a re-pick clears it, which deletes this row and
  /// enqueues a fresh `pending` one; a rejected row is never resurrected in
  /// place, so it never inherits a stale retry count or error.
  Future<void> markRejected(int id, {required String errorMessage}) async {
    await _db.rawUpdate(
      '''
      UPDATE pending_attachments
        SET state = ?, error_message = ?,
            retry_count = retry_count + 1,
            last_attempt_at = ?
        WHERE id = ?
      ''',
      [
        AttachmentState.rejected.wireName,
        errorMessage,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        id,
      ],
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
