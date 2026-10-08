/// The attach/image value that is currently LIVE for a form field.
///
/// [hasInteractedByUser] is the only thing separating "the user cleared this"
/// from "never touched", and both readings are needed:
///
/// - Trusting [fieldValue] alone makes a discard work but loses a value that
///   arrives AFTER the first build (an async document load) — `initialValue`
///   applies once, the field's key is stable so its `State` survives the
///   rebuild, and the new widget value is ignored.
/// - Falling back to [widgetValue] unconditionally makes an explicit clear
///   impossible to represent.
///
/// Shared rather than inlined because two call sites per field read this — the
/// pick path (reclaiming what a new pick replaces) and the discard path — and
/// they DIVERGED: the pick path read `fieldState.value` raw, so before the first
/// interaction it reclaimed null while the discard path reclaimed the real
/// value. A staged file a pick replaced was therefore leaked until the orphan
/// sweep found it. Sharing the expression is what makes disagreeing impossible.
///
/// The result is trimmed: `MediaStore.isStagedPath` canonicalises whatever it is
/// handed, so an untrimmed path is a different string to the guard that decides
/// whether a file may be deleted.
String? liveAttachmentValue({
  required bool hasInteractedByUser,
  required Object? fieldValue,
  required Object? widgetValue,
}) {
  final field = fieldValue?.toString();
  final widget = widgetValue?.toString();
  final live = hasInteractedByUser ? field : (widget ?? field);
  return live?.trim();
}

/// Directory, under the OS temp root, holding attachments downloaded purely so
/// the device's default app can open them.
///
/// A NAMED subdirectory rather than loose files in the temp root makes the cache
/// identifiable and lets the OS reclaim it as a unit.
///
/// Deliberately NOT under `MediaStore`'s own root: it is a viewer scratch area,
/// not correctness storage. That distinction is why it needs explicit handling —
/// `clearAll`, `sweepOrphans` and `usage` all walk `MediaStore`'s root and can
/// never reach here, so for a while nothing wiped it, including
/// `logout(clearDatabase: true)`.
const String attachmentTempDirName = 'frappe_attachments';

/// Marker file, directly in the OS temp root, naming the field that launched the
/// camera so an interrupted capture can be handed back to the right one.
///
/// Declared here for the same reason as [attachmentTempDirName]: `MediaStore`
/// must be able to delete it on logout without importing a widget file.
///
/// Both constants carried `@visibleForTesting` while each was private to the
/// widget that wrote it. That no longer holds — `MediaStore` is a production
/// caller of both, which is the entire point of moving them — so the annotation
/// is deliberately absent. Neither name is exported from `frappe_mobile_sdk.dart`,
/// so neither is public API. Holds a
/// `fieldtype/fieldname` key — no attachment content — but it must NOT outlive a
/// session, or a recovered photo can land on a field belonging to the next user.
const String cameraCaptureMarkerFileName = 'frappe_sdk_camera_capture.marker';

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

/// The auth [headers] to send with a request for [url], or null.
///
/// Auth headers (a Frappe session token) belong to the Frappe host only. A file
/// value can be an absolute URL on another host — object storage or a CDN — and
/// sending the token there leaks it to a third party. Object stores also reject
/// a foreign `Authorization` header outright, so the file fails to load.
///
/// Returns [headers] when [url] is relative or has the same scheme, host and
/// port as [baseUrl]; null for any other origin. A protocol-relative URL
/// (`//host/x`) is compared using the base's scheme. Without a [baseUrl] the origin
/// cannot be checked, so [headers] pass through unchanged.
Map<String, String>? authHeadersForUrl(
  String? url,
  Map<String, String>? headers,
  String? baseUrl,
) {
  if (headers == null) return null;
  final base = baseUrl?.trim() ?? '';
  if (base.isEmpty) return headers;
  var target = Uri.tryParse(url?.trim() ?? '');
  if (target == null) return null;
  // A relative path resolves against the base, so it is same-origin.
  if (!target.hasScheme && target.host.isEmpty) return headers;
  final origin = Uri.tryParse(base);
  if (origin == null || !origin.hasScheme) return headers;
  // A protocol-relative URL (`//cdn.example.com/x.jpg`) names a host: give it
  // the site's scheme and compare it like any absolute URL.
  if (!target.hasScheme) target = origin.resolveUri(target);
  final sameOrigin =
      target.scheme.toLowerCase() == origin.scheme.toLowerCase() &&
      target.host.toLowerCase() == origin.host.toLowerCase() &&
      target.port == origin.port;
  return sameOrigin ? headers : null;
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
