import 'dart:io';

import 'package:flutter/foundation.dart';

import '../database/daos/pending_attachment_dao.dart';
import '../models/pending_attachment.dart';
import 'push_error.dart';

typedef AttachmentUploadFn =
    Future<Map<String, dynamic>> Function(
      File file, {
      String? doctype,
      String? docname,
      String? fileName,
      bool isPrivate,
    });

typedef FileFromPathFn = File Function(String path);

class AttachmentUploadResult {
  final String fileName;
  final String fileUrl;
  const AttachmentUploadResult({required this.fileName, required this.fileUrl});
}

/// Uploads any `pending_attachments` rows queued for a given parent doc
/// before the parent itself is pushed. Spec §5.3.
///
/// Each upload retries with backoff (default 2s/5s/10s, 3 attempts). On
/// terminal failure throws [BlockedByUpstream] so the caller flips the
/// outbox row to `blocked` until the user reattaches or retries.
///
/// Once attachments are uploaded, [inlinePayload] walks the assembled
/// payload and rewrites every `pending:<id>` marker (left there by
/// `attach_field.dart` on offline pick) with the resolved server
/// `file_url`.
class AttachmentPipeline {
  final PendingAttachmentDao dao;
  final AttachmentUploadFn uploader;
  final List<Duration> backoff;
  final FileFromPathFn fileFromPath;

  AttachmentPipeline({
    required this.dao,
    required this.uploader,
    this.backoff = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    this.fileFromPath = _defaultFileFromPath,
  });

  static File _defaultFileFromPath(String p) => File(p);

  /// Uploads every pending attachment for [topParentUuid] (the outbox
  /// row's mobile_uuid). Includes attachments queued against child-row
  /// uuids whose `top_parent_uuid` was set to [topParentUuid] at enqueue.
  /// Returns a map of `pending_attachments.id` → upload result. Throws
  /// BlockedByUpstream if any attachment exhausts its retries.
  Future<Map<int, AttachmentUploadResult>> uploadPendingForTopParent(
    String topParentUuid,
  ) async {
    final pending = await dao.findPendingForTopParent(topParentUuid);
    final results = <int, AttachmentUploadResult>{};
    for (final p in pending) {
      results[p.id] = await _uploadOne(p);
    }
    return results;
  }

  Future<AttachmentUploadResult> _uploadOne(PendingAttachment p) async {
    await dao.markUploading(p.id);
    Object? lastError;
    for (var attempt = 0; attempt < backoff.length; attempt++) {
      try {
        // No `doctype` and no `docname` — File row is created fully
        // unattached (all attached_to_* are NULL). v16's File controller
        // rejects `attached_to_doctype` without a non-empty
        // `attached_to_name` (file.py:151), so we can't ship `dt` alone.
        //
        // Relink path:
        //   - Parent docs: Frappe's stock `attach_files_to_document`
        //     (registered on `*.on_update` in apps/frappe/frappe/hooks.py)
        //     finds unattached File rows by file_url and rewires them.
        //   - Child rows: stock skips children (they save via raw
        //     `db_update`, no lifecycle hooks). The mobile_control hook
        //     `relink_mobile_files` walks the parent's child tables on
        //     `*.on_update` and rewires per-child.
        // Spec §5.3.
        final resp = await uploader(
          fileFromPath(p.localPath),
          fileName: p.fileName,
          isPrivate: p.isPrivate,
        );
        final fileUrl = resp['file_url'] as String;
        final fileName = resp['name'] as String? ?? fileUrl;
        await dao.markDone(
          p.id,
          serverFileName: fileName,
          serverFileUrl: fileUrl,
        );
        return AttachmentUploadResult(fileName: fileName, fileUrl: fileUrl);
      } catch (e, st) {
        debugPrint(
          'AttachmentPipeline.upload(${p.id}) attempt $attempt failed — $e\n$st',
        );
        lastError = e;
        if (attempt < backoff.length - 1) {
          await Future<void>.delayed(backoff[attempt + 1]);
        }
      }
    }
    await dao.markFailed(p.id, errorMessage: '$lastError');
    throw BlockedByUpstream(
      field: p.parentFieldname,
      targetDoctype: 'File',
      targetUuid: '${p.id}',
    );
  }

  /// Walks a payload (parent + children), replacing any `pending:<id>`
  /// string value with the uploaded `file_url` from [resolved]. Markers
  /// without a matching entry pass through unchanged (caller can decide
  /// whether to retry later).
  static Map<String, Object?> inlinePayload(
    Map<String, Object?> payload, {
    required Map<int, AttachmentUploadResult> resolved,
  }) {
    final out = <String, Object?>{};
    for (final entry in payload.entries) {
      final v = entry.value;
      if (v is String && v.startsWith('pending:')) {
        final id = int.tryParse(v.substring('pending:'.length));
        final r = id == null ? null : resolved[id];
        out[entry.key] = r?.fileUrl ?? v;
      } else if (v is List) {
        out[entry.key] = v.map((e) {
          if (e is Map) {
            return inlinePayload(
              Map<String, Object?>.from(e),
              resolved: resolved,
            );
          }
          return e;
        }).toList();
      } else {
        out[entry.key] = v;
      }
    }
    return out;
  }
}
