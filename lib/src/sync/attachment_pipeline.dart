import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../concurrency/write_queue.dart';
import '../database/daos/media_cache_dao.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../models/media_cache_entry.dart';
import '../models/pending_attachment.dart';
import '../utils/attachment_paths.dart';
import '../utils/media_store.dart';
import '../utils/sdk_log.dart';
import 'attachment_error_classifier.dart';
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

/// Default retry-backoff schedule used by [AttachmentPipeline] and
/// [PushEngine]'s `attachmentBackoff` / `networkBackoff` parameters. Defined
/// once so a product-side schedule change doesn't have to update three
/// default-parameter sites.
///
/// **The two consumers read this list differently, so it does not describe one
/// attempt count.** Both are correct for their own loop; only a single
/// "3 attempts at 2s, 5s, 10s" summary was ever wrong, because it fit neither.
///
/// | Consumer | Loop bound | Attempts | Delays actually used |
/// |---|---|---|---|
/// | [AttachmentPipeline] | `attempt < backoff.length` | **3** | `2s`, `5s` |
/// | `PushEngine` | `attempt <= networkBackoff.length` | **4** | `2s`, `5s`, `10s` |
///
/// In the pipeline the list length IS the attempt count, and the delay is taken
/// only when another attempt follows (`attempt < backoff.length - 1`) — so the
/// final entry, `10s`, is never slept on. Two consequences worth knowing before
/// editing this list:
///
/// * **Trimming it changes the pipeline's attempt count, not just its waits.**
///   Cutting to `[2s, 5s]` silently drops the pipeline from 3 attempts to 2
///   while leaving `PushEngine` at 3.
/// * **Appending to it adds a pipeline attempt** and a `PushEngine` delay.
///
/// Deliberately left as one shared list rather than split per consumer: the
/// product-side reason to change a backoff schedule applies to both, and the
/// asymmetry is in the loops, not in the data.
const List<Duration> kDefaultSyncBackoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
];

class AttachmentUploadResult {
  final String fileName;
  final String fileUrl;
  const AttachmentUploadResult({required this.fileName, required this.fileUrl});
}

/// Resolves every attachment for a document before its parent is pushed.
///
/// ## The commitment model
///
/// A `server_file_url` COMMITTED TO SQLITE is the correctness boundary. Once
/// committed, the file is uploaded — permanently — regardless of whether the
/// parent document ever syncs, and no later attempt may re-upload it. A url
/// that was received but not yet committed is NOT a fact the pipeline may rely
/// on: that window degrades to a re-upload, which Frappe's content-hash dedup
/// resolves by returning the same url for identical bytes.
///
/// ## The push gate
///
/// A parent doc may only push when EVERY one of its attachments is `done`.
/// Anything else throws [BlockedByUpstream]. Silently skipping a non-done row
/// is what previously let a raw `pending:<id>` marker reach Frappe verbatim.
///
/// ## Ordering
///
/// There is no transaction spanning the filesystem and SQLite, so the steps are
/// ordered to make every crash point resumable:
///
///   1. upload                       (nothing durable yet)
///   2. recordUpload                 <- the correctness boundary
///   3. move staged bytes -> cache/  (idempotent)
///   4. ONE txn: markDone + writeback + media_cache insert
///
/// Because step 2 commits first, a crash anywhere after it means the next
/// dispatch skips the upload entirely and resumes where it stopped.
class AttachmentPipeline {
  final PendingAttachmentDao dao;
  final AttachmentUploadFn uploader;
  final List<Duration> backoff;
  final FileFromPathFn fileFromPath;
  final Database db;

  /// Resolves the `docs__<doctype>` mirror table for the writeback.
  final Future<String?> Function(String doctype)? tableNameFor;

  /// Resolves the per-doctype [WriteQueue] that serializes `docs__` writes.
  ///
  /// Null in tests and when the host wires no resolver; the step-4 txn then
  /// falls back to a bare `db.transaction`, matching push_engine's own
  /// if/else. Writing to `docs__<doctype>` outside that queue would race the
  /// response-writeback and the auto-merge persist.
  final WriteQueue? Function(String doctype)? writeQueueFor;

  AttachmentPipeline({
    required this.dao,
    required this.uploader,
    required this.db,
    this.backoff = kDefaultSyncBackoff,
    this.fileFromPath = _defaultFileFromPath,
    this.tableNameFor,
    this.writeQueueFor,
  });

  static File _defaultFileFromPath(String p) => File(p);

  /// Resolves all attachments for [topParentUuid], uploading what is
  /// outstanding.
  ///
  /// Returns `pending_attachments.id` -> result for every row resolved in this
  /// pass. Throws [BlockedByUpstream] if any attachment cannot be resolved —
  /// that is the push gate.
  Future<Map<int, AttachmentUploadResult>> resolveForTopParent(
    String topParentUuid,
  ) async {
    final outstanding = await dao.findUnresolvedForTopParent(topParentUuid);
    final results = <int, AttachmentUploadResult>{};
    for (final p in outstanding) {
      results[p.id] = await _resolveOne(p);
    }
    return results;
  }

  /// Builds the marker-resolution map from EVERY row for the doc, including
  /// `done` ones.
  ///
  /// Backstop for a marker whose writeback was interrupted. Given the atomic
  /// step-4 txn this should be unreachable — a hit means the atomicity
  /// assumption broke, not normal operation.
  Future<Map<int, AttachmentUploadResult>> resolutionMapFor(
    String topParentUuid,
  ) async {
    final all = await dao.findAllForTopParent(topParentUuid);
    final out = <int, AttachmentUploadResult>{};
    for (final p in all) {
      final url = p.serverFileUrl;
      if (url == null) continue;
      out[p.id] = AttachmentUploadResult(
        fileName: p.serverFileName ?? url,
        fileUrl: url,
      );
    }
    return out;
  }

  Future<AttachmentUploadResult> _resolveOne(PendingAttachment p) async {
    // A terminal rejection is never retried. Block immediately so the user
    // sees an actionable reason instead of an endless retry loop.
    if (p.state == AttachmentState.rejected) {
      throw _blocked(p, p.errorMessage ?? 'previously rejected');
    }

    // STEPS 1-2: upload, then COMMIT the url before anything else can fail.
    var fileUrl = p.serverFileUrl;
    var fileName = p.serverFileName;
    if (fileUrl == null) {
      await dao.markUploading(p.id);
      Object? lastError;
      for (var attempt = 0; attempt < backoff.length; attempt++) {
        try {
          // No `doctype`/`docname`: the File row is created fully unattached
          // (all attached_to_* NULL). v16's File controller rejects
          // `attached_to_doctype` without a non-empty `attached_to_name`, so
          // we cannot ship the doctype alone. Frappe's stock
          // `attach_files_to_document` rewires parents; mobile_control's
          // `relink_mobile_files` handles child rows, which stock skips
          // because children save via raw db_update with no lifecycle hooks.
          final resp = await uploader(
            fileFromPath(p.localPath),
            fileName: p.fileName,
            isPrivate: p.isPrivate,
          );
          fileUrl = resp['file_url'] as String;
          fileName = resp['name'] as String? ?? fileUrl;
          await dao.recordUpload(
            p.id,
            serverFileName: fileName,
            serverFileUrl: fileUrl,
          );
          break;
        } catch (e, st) {
          sdkLog(
            'AttachmentPipeline.upload(${p.id}) attempt $attempt failed — $e\n$st',
          );
          lastError = e;
          if (isTerminalAttachmentError(e)) {
            await dao.markRejected(p.id, errorMessage: '$e');
            throw _blocked(p, '$e');
          }
          // Delay BEFORE the next attempt; the last attempt has no "next".
          if (attempt < backoff.length - 1) {
            await Future<void>.delayed(backoff[attempt]);
          }
        }
      }
      if (fileUrl == null) {
        final reason = lastError?.toString() ?? 'unknown error';
        await dao.markFailed(p.id, errorMessage: reason);
        throw _blocked(p, reason);
      }
    }

    // STEP 3: move staged bytes into the cache. Idempotent, so an interrupted
    // run resumes here. Cache failure NEVER fails the upload — the url is
    // already committed, so the upload genuinely succeeded.
    //
    // The destination comes back FROM the move rather than being recomputed
    // here. `cachePathFor` borrows the extension from the staged file when the
    // url carries none, so recomputing it without the source named `<digest>`
    // while the bytes landed at `<digest><ext>` — a `media_cache` row pointing
    // at a file that was never written, which reads as a permanent cache miss
    // and strands the real bytes where no sweep reclaims them.
    var cachedPath = '';
    var moved = false;
    try {
      final dest = await MediaStore.moveToCache(p.localPath, fileUrl);
      moved = dest != null;
      if (dest != null) cachedPath = dest;
    } catch (e, st) {
      sdkLog('AttachmentPipeline: cache move failed for ${p.id} — $e\n$st');
    }
    if (!moved) {
      // The bytes are already on the server, so the staged copy is redundant.
      // Without this it would linger forever: nothing else reclaims outbox/,
      // and the row is about to go `done` so no later pass would revisit it.
      // We lose the cache entry (the file re-downloads on first view), not
      // the data.
      await MediaStore.deleteOutboxCopy(p.localPath);
    }

    // Pre-resolved OUTSIDE the txn: querying through the outer Database while
    // holding a txn deadlocks sqflite's non-reentrant lock (a Dart deadlock,
    // not SQLITE_BUSY).
    final table = await _tableFor(p.parentDoctype);
    final resolvedUrl = fileUrl;
    final resolvedName = fileName ?? fileUrl;

    // STEP 4: ONE txn — markDone + writeback + cache index. Atomic so the
    // column and the row can never disagree.
    Future<void> writes(Transaction txn) async {
      await PendingAttachmentDao(txn).markDone(
        p.id,
        serverFileName: resolvedName,
        serverFileUrl: resolvedUrl,
      );
      if (table != null) {
        // CONDITIONAL on the column still holding THIS row's marker.
        //
        // An unconditional update assumes nothing changed underneath it, which
        // is the same mistake that produced the original marker bug. If the
        // user discarded the attachment or re-picked while this upload was in
        // flight, the column no longer holds `pending:<id>` — writing anyway
        // would resurrect a discarded file, or let an old upload claim the new
        // pick's slot. Matching nothing is the correct outcome there.
        //
        // Every legitimate path still matches: the normal case and the
        // crash-then-resume case both have the marker in the column. A re-run
        // after the writeback already landed finds the url instead and
        // correctly no-ops.
        await txn.update(
          table,
          <String, Object?>{p.parentFieldname: resolvedUrl},
          where: 'mobile_uuid = ? AND "${p.parentFieldname}" = ?',
          whereArgs: [p.parentUuid, '$kPendingMarkerPrefix${p.id}'],
        );
      }
      if (cachedPath.isNotEmpty) {
        await MediaCacheDao(txn).upsert(
          fileUrl: resolvedUrl,
          localPath: cachedPath,
          sizeBytes: p.sizeBytes,
          mimeType: p.mimeType,
          isPrivate: p.isPrivate,
          source: MediaSource.uploaded,
        );
      }
    }

    try {
      final wq = writeQueueFor?.call(p.parentDoctype);
      if (wq != null) {
        await wq.submit<void>(writes);
      } else {
        await db.transaction(writes);
      }
    } catch (e, st) {
      // Never rethrown: the url is already committed, so reporting a failure
      // here would contradict the commitment model. The next dispatch skips
      // the upload and retries the move + txn.
      sdkLog('AttachmentPipeline: step-4 txn failed for ${p.id} — $e\n$st');
    }

    return AttachmentUploadResult(fileName: resolvedName, fileUrl: resolvedUrl);
  }

  Future<String?> _tableFor(String doctype) async {
    final resolver = tableNameFor;
    if (resolver == null) return null;
    try {
      return await resolver(doctype);
    } catch (e, st) {
      sdkLog('AttachmentPipeline: tableNameFor($doctype) failed — $e\n$st');
      return null;
    }
  }

  /// Names the FILE and FIELD, not a row id — a user cannot act on `File/42`.
  BlockedByUpstream _blocked(PendingAttachment p, String reason) =>
      BlockedByUpstream(
        field: p.parentFieldname,
        targetDoctype: 'File',
        targetUuid: p.fileName ?? '${p.id}',
        reason:
            '${p.fileName ?? 'attachment'} (${p.parentFieldname}) — $reason',
      );

  /// Walks a payload (parent + children), replacing every `pending:<id>`
  /// marker with its resolved `file_url`.
  ///
  /// THROWS on an unresolved marker. An unresolved marker on the wire is never
  /// correct, and it used to be indistinguishable from a legitimate value — a
  /// document would push "successfully" with the literal string `pending:42`
  /// stored in Frappe. Under the push gate this should be unreachable; it
  /// exists so any future regression is loud instead of silent.
  static Map<String, Object?> inlinePayload(
    Map<String, Object?> payload, {
    required Map<int, AttachmentUploadResult> resolved,
  }) {
    final out = <String, Object?>{};
    for (final entry in payload.entries) {
      final v = entry.value;
      if (v is String && v.startsWith(kPendingMarkerPrefix)) {
        final id = int.tryParse(v.substring(kPendingMarkerPrefix.length));
        final r = id == null ? null : resolved[id];
        if (r == null) {
          throw StateError(
            'Unresolved attachment marker "$v" for field "${entry.key}" '
            'reached the payload. The push gate should have blocked this '
            'document.',
          );
        }
        out[entry.key] = r.fileUrl;
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
