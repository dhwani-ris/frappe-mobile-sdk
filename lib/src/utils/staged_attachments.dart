import 'package:path/path.dart' as p;

import 'media_store.dart';
import 'sdk_log.dart';

/// Uploads one staged file and returns its server `file_url`.
typedef StagedUploadFn = Future<String> Function(String stagedPath);

/// Raised when a staged attachment could not be uploaded before an online
/// save. The save is abandoned rather than sending the device path to the
/// server as the field's value.
class StagedAttachmentUploadException implements Exception {
  final String fileName;
  final Object cause;
  const StagedAttachmentUploadException(this.fileName, this.cause);

  @override
  String toString() =>
      'Could not upload $fileName. Check your connection and try again.';
}

/// Every value in [payload] — top level and child-table rows — that is a file
/// staged in this SDK's `outbox/`.
///
/// Matches on outbox containment ([MediaStore.isStagedPath]) rather than
/// field type: a value inside `outbox/` can only be an attachment picked
/// through the SDK, and this needs no child-table meta to walk the rows.
Future<Set<String>> stagedAttachmentPathsIn(
  Map<String, dynamic> payload,
) async {
  final out = <String>{};
  Future<void> scan(Map<dynamic, dynamic> row) async {
    for (final v in row.values) {
      if (v is String) {
        if (await MediaStore.isStagedPath(v)) out.add(v.trim());
      } else if (v is List) {
        for (final e in v) {
          if (e is Map) await scan(e);
        }
      }
    }
  }

  try {
    await scan(payload);
  } catch (e, st) {
    // The store root could not be resolved (no path_provider, e.g. a stripped
    // embedder). Nothing can have been staged without it, and a save must not
    // fail over a check that has nothing to find.
    sdkLog('stagedAttachmentPathsIn: store unavailable — $e\n$st');
    return <String>{};
  }
  return out;
}

/// A copy of [payload] with every value found in [replacements] swapped for
/// its mapped value, in the parent and in child-table rows.
Map<String, dynamic> replaceAttachmentValues(
  Map<String, dynamic> payload,
  Map<String, String> replacements,
) {
  if (replacements.isEmpty) return payload;
  Map<String, dynamic> walk(Map<dynamic, dynamic> row) => {
    for (final e in row.entries)
      e.key.toString(): switch (e.value) {
        final String s => replacements[s.trim()] ?? s,
        final List l => [for (final x in l) x is Map ? walk(x) : x],
        final v => v,
      },
  };
  return walk(payload);
}

/// Uploads each of [paths] not already in [known] and returns path → url for
/// all of them.
///
/// Throws [StagedAttachmentUploadException] on the first failure, so a caller
/// never saves a document whose attach field still holds a device path.
Future<Map<String, String>> uploadStagedAttachments(
  Set<String> paths,
  StagedUploadFn upload, {
  Map<String, String> known = const {},
}) async {
  final out = <String, String>{};
  for (final path in paths) {
    final hit = known[path];
    if (hit != null) {
      out[path] = hit;
      continue;
    }
    try {
      out[path] = await upload(path);
    } catch (e, st) {
      sdkLog('uploadStagedAttachments: $path failed — $e\n$st');
      throw StagedAttachmentUploadException(p.basename(path), e);
    }
  }
  return out;
}
