/// Classifies an attach-field value as a durable local file that still needs
/// to be uploaded.
///
/// Returns `true` only for a non-empty string that is a local filesystem path
/// — i.e. NOT already a Frappe server file URL and NOT a `pending:<id>` marker
/// left by the save-time enqueue. The `pending:` exclusion is essential: it
/// stops a re-save of an unsynced document from re-classifying an
/// already-queued field as a fresh local file and enqueueing garbage.
bool isLocalAttachmentPath(Object? value) {
  if (value is! String) return false;
  final p = value.trim();
  if (p.isEmpty) return false;
  const nonLocalPrefixes = [
    '/files/',
    '/private/files/',
    '/api/method/',
    'http://',
    'https://',
    kPendingMarkerPrefix,
  ];
  for (final prefix in nonLocalPrefixes) {
    if (p.startsWith(prefix)) return false;
  }
  return true;
}

/// Prefix marking a field value whose file is queued in `pending_attachments`
/// but not yet uploaded. Written by the save-time producer; resolved to a real
/// `file_url` by the push pipeline's `inlinePayload`.
const String kPendingMarkerPrefix = 'pending:';

/// Parses the numeric id out of a `pending:<id>` marker, or null if [value]
/// is not a well-formed marker.
int? parsePendingMarkerId(Object? value) {
  if (value is! String) return null;
  final p = value.trim();
  if (!p.startsWith(kPendingMarkerPrefix)) return null;
  return int.tryParse(p.substring(kPendingMarkerPrefix.length));
}

/// Resolves an attach/image field value to the source used for PREVIEW only.
///
/// A `pending:<id>` marker maps to its durable local file via [pendingPaths]
/// (id → local path); if the id is unknown (file gone / map stale) the result
/// is null and the caller shows a broken-image placeholder while keeping the
/// marker as the stored value. Any other value (server URL or local path) is
/// returned unchanged. The stored/submitted field value is NEVER changed by
/// this — display resolution must not leak into the marker/inlinePayload
/// contract.
String? attachmentDisplaySource(Object? value, Map<int, String>? pendingPaths) {
  if (value is! String) return null;
  final p = value.trim();
  if (p.isEmpty) return null;
  final id = parsePendingMarkerId(p);
  if (id != null) return pendingPaths?[id];
  return p;
}

/// Builds the absolute, authenticated URL used to fetch a stored attach-field
/// value from Frappe.
///
/// - Full `http(s)` URLs (S3 and friends) pass through unchanged.
/// - `/files/` and `/private/files/` go through `frappe.handler.download_file`
///   so the request carries auth and private files resolve.
/// - Any other rooted path just gets [baseUrl] prepended.
///
/// Returns the input unchanged when there is no usable [baseUrl], so callers
/// degrade to "not fetchable" rather than building a broken request.
///
/// `AttachField._fullFileUrl` and `ImageField._fullImageUrl` both delegate here;
/// they were private copies of this logic until the three were collapsed. Keep
/// it that way — `/private/files/` must route through `download_file` to carry
/// auth, so a drift between copies is a private-file 404. Every branch is pinned
/// by `test/utils/attachment_paths_test.dart`.
String? frappeFileFetchUrl(String? path, String? baseUrl) {
  if (path == null || path.isEmpty) return path;
  final p = path.trim();
  if (p.isEmpty) return path;
  if (p.startsWith('http://') || p.startsWith('https://')) return p;
  if (!p.startsWith('/') || baseUrl == null || baseUrl.trim().isEmpty) {
    return p;
  }
  final base = baseUrl.trim();
  final baseNoSlash = base.endsWith('/')
      ? base.substring(0, base.length - 1)
      : base;
  if (p.startsWith('/private/files/') || p.startsWith('/files/')) {
    return '$baseNoSlash/api/method/frappe.handler.download_file'
        '?file_url=${Uri.encodeComponent(p)}';
  }
  return '$baseNoSlash$p';
}

/// Extension → MIME type for the attachment kinds a Frappe mobile form
/// realistically carries.
///
/// A small table rather than the `mime` package: this SDK ships to pub.dev and
/// a new direct dependency is a heavier cost than a dozen mappings. Returns
/// null for anything unrecognised — `pending_attachments.mime_type` is
/// diagnostic metadata, and the server derives the authoritative type itself.
const Map<String, String> _mimeByExtension = <String, String>{
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.heic': 'image/heic',
  '.pdf': 'application/pdf',
  '.txt': 'text/plain',
  '.csv': 'text/csv',
  '.doc': 'application/msword',
  '.docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.mp4': 'video/mp4',
  '.m4a': 'audio/mp4',
  '.mp3': 'audio/mpeg',
  '.zip': 'application/zip',
};

/// Best-effort MIME type for [path], or null when the extension is unknown.
String? mimeTypeForPath(String? path) {
  if (path == null) return null;
  final trimmed = path.trim();
  final dot = trimmed.lastIndexOf('.');
  if (dot <= 0 || dot == trimmed.length - 1) return null;
  if (dot < trimmed.lastIndexOf('/')) return null;
  return _mimeByExtension[trimmed.substring(dot).toLowerCase()];
}
