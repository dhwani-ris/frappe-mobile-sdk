import 'dart:io';

import 'media_store.dart';

export 'media_store.dart' show kAttachmentStoreDir;

/// Copies [source] into the outbox staging area and returns the durable path.
///
/// Retained as the historical entry point; delegates to [MediaStore]. Bytes now
/// land in `mform_attachments/outbox/` rather than flat under
/// `mform_attachments/`, so they are separable from the evictable cache.
Future<String> copyToAttachmentStore(
  File source, {
  String Function()? nameGen,
}) => MediaStore.stageToOutbox(source, nameGen: nameGen);

/// Best-effort delete of a staged copy. Never throws.
Future<void> deleteAttachmentCopy(String path) =>
    MediaStore.deleteOutboxCopy(path);
