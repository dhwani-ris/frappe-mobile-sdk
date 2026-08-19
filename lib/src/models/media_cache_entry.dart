import '../utils/sql_row_utils.dart';

/// How a cached file arrived on the device.
///
/// `uploaded` — this device created it; the staged file was moved into the
/// cache after a successful upload, so it was never downloaded.
/// `downloaded` — fetched from the server to render a document pulled from
/// elsewhere.
///
/// Phase 2's eviction may weight these differently (uploaded bytes are cheaper
/// to lose only once the server copy is confirmed). Phase 1 just records it.
enum MediaSource { uploaded, downloaded }

extension MediaSourceHelpers on MediaSource {
  String get wireName => name;

  static MediaSource parse(String raw) {
    final value = parseEnumByName(MediaSource.values, raw);
    if (value == null) throw ArgumentError.value(raw, 'media_source');
    return value;
  }
}

/// One row of the `media_cache` content store, keyed by the server [fileUrl].
///
/// Cache entries are NON-AUTHORITATIVE: the bytes can always be re-fetched
/// from [fileUrl], so an entry whose [localPath] no longer exists is a cache
/// miss rather than an error.
class MediaCacheEntry {
  final String fileUrl;
  final String localPath;
  final int? sizeBytes;
  final String? mimeType;
  final bool isPrivate;
  final MediaSource source;
  final DateTime createdAt;
  final DateTime? lastAccessedAt;

  const MediaCacheEntry({
    required this.fileUrl,
    required this.localPath,
    this.sizeBytes,
    this.mimeType,
    required this.isPrivate,
    required this.source,
    required this.createdAt,
    this.lastAccessedAt,
  });

  factory MediaCacheEntry.fromMap(Map<String, Object?> row) {
    final accessed = row['last_accessed_at'] as int?;
    return MediaCacheEntry(
      fileUrl: row['file_url'] as String,
      localPath: row['local_path'] as String,
      sizeBytes: row['size_bytes'] as int?,
      mimeType: row['mime_type'] as String?,
      isPrivate: (row['is_private'] as int? ?? 1) == 1,
      source: MediaSourceHelpers.parse(row['source'] as String),
      createdAt: utcMillisFrom(row, 'created_at'),
      lastAccessedAt: accessed == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(accessed, isUtc: true),
    );
  }
}
