import 'dart:io';

import '../sync/attachment_error_classifier.dart';
import 'attachment_storage.dart';
import 'sdk_log.dart';

/// Uploads a picked file to the Frappe server, returning the stored file
/// reference (`file_url`) or null on failure. Matches the closure the SDK's
/// `FormScreen` wires from `api.attachment.uploadFile`.
typedef AttachmentUploadFn = Future<String?> Function(File file);

/// Default ceiling on a picked attachment, matching Frappe's stock System
/// Settings `max_file_size` (10 MB).
///
/// **Not currently reachable from a host.** It is the default for
/// [resolvePickedAttachment]'s `maxBytes`, and the only callers are this SDK's
/// own `AttachField` / `ImageField`, which do not expose an override — so a
/// deployment whose server limit differs cannot change it without threading a
/// parameter through `FormScreen` -> `FormBuilder` -> `FieldFactory`.
///
/// Reading the true server value would need `mobile_control` to expose
/// System Settings' `max_file_size`. Until either exists, a wrong default only
/// ever refuses early, which is recoverable, rather than letting an
/// unuploadable file into the queue.
const int kDefaultMaxAttachmentBytes = 10 * 1024 * 1024;

/// Thrown when a picked file exceeds the size limit.
///
/// Raised at PICK time, before the durable copy is made, so the user can
/// re-take the photo. Left to fail at push time it would instead surface as a
/// blocked document long after the moment had passed.
class AttachmentTooLargeException implements Exception {
  final int sizeBytes;
  final int limitBytes;
  const AttachmentTooLargeException(this.sizeBytes, this.limitBytes);

  @override
  String toString() =>
      'AttachmentTooLargeException: $sizeBytes bytes exceeds the '
      '$limitBytes byte limit';
}

/// Resolves a just-picked attachment file into the value a field should store.
///
/// Always copies the picked file into the durable attachment store FIRST — the
/// picker/camera hands back a volatile cache path the OS can reclaim (and the
/// host process can be killed mid-capture), so the durable copy is the safety
/// net for both online and offline.
///
/// - **Online, offline mode OFF**, with an [uploadFile]: upload from the durable
///   copy; on success return the server `file_url` and delete the now-redundant
///   copy.
/// - **[offlineModeEnabled] is true**: never upload here, whatever the
///   connectivity. Return the staged path so the save-time producer queues it
///   and the push pipeline owns it. See the note on that parameter.
/// - **Offline**, no uploader, or a TRANSIENT upload failure: return the durable
///   local path so the save-time producer can queue it for later upload.
/// - **A TERMINAL upload failure** (oversized, wrong type, not permitted)
///   rethrows and discards the copy. Queueing a file the server has already
///   refused would only guarantee a blocked push later.
///
/// Throws [AttachmentTooLargeException] when the pick exceeds [maxBytes].
///
/// [copyToStore] / [deleteCopy] are injectable for testing.
Future<String?> resolvePickedAttachment({
  required File picked,
  required bool online,
  AttachmentUploadFn? uploadFile,

  /// When true, defer the upload to the push pipeline even if [online].
  ///
  /// Offline-first mode promises that data entry never blocks on the network.
  /// Uploading inline here would break that promise on a connected device, and
  /// would also put the attachment OUTSIDE the offline pipeline: no
  /// `pending_attachments` row, so no push gate, no `rejected` state, no cache
  /// entry, and — because nothing records the upload — a discarded draft would
  /// leave an orphaned File on the server that the SDK cannot even name.
  ///
  /// Defaults to false so a host that does not supply it keeps the previous
  /// inline-upload behaviour.
  bool offlineModeEnabled = false,
  int maxBytes = kDefaultMaxAttachmentBytes,
  Future<String> Function(File source) copyToStore = copyToAttachmentStore,
  Future<void> Function(String path) deleteCopy = deleteAttachmentCopy,
}) async {
  // Checked BEFORE staging so an oversized pick never occupies disk.
  //
  // A file we cannot stat skips the guard rather than being refused: failing to
  // measure is not evidence of being too large, and blocking a legitimate pick
  // is the worse error.
  try {
    final size = await picked.length();
    if (size > maxBytes) {
      throw AttachmentTooLargeException(size, maxBytes);
    }
  } on AttachmentTooLargeException {
    rethrow;
  } catch (e, st) {
    sdkLog(
      'resolvePickedAttachment: could not size ${picked.path}, '
      'skipping the guard — $e\n$st',
    );
  }

  final durablePath = await copyToStore(picked);
  if (uploadFile != null && online && !offlineModeEnabled) {
    try {
      final url = await uploadFile(File(durablePath));
      if (url != null && url.isNotEmpty) {
        await deleteCopy(durablePath);
        return url;
      }
    } catch (e, st) {
      sdkLog('resolvePickedAttachment: upload failed — $e\n$st');
      if (isTerminalAttachmentError(e)) {
        // The server will refuse this file every time. Discard the staged copy
        // and surface it now, while the user can still act on it.
        await deleteCopy(durablePath);
        rethrow;
      }
      // Transient: keep the durable copy; the save-time producer queues it.
    }
  }
  return durablePath;
}

/// User-facing message for an [AttachmentTooLargeException].
///
/// Names the actual limit in MB: "file too large" alone leaves the user
/// guessing how much to trim.
String attachmentTooLargeMessage(AttachmentTooLargeException e) {
  String mb(int bytes) {
    final v = bytes / (1024 * 1024);
    return v >= 10 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  }

  return 'This file is ${mb(e.sizeBytes)} MB, over the '
      '${mb(e.limitBytes)} MB limit. Attach a smaller file.';
}
