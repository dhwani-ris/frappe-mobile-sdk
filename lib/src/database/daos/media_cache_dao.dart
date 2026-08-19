import 'package:sqflite/sqflite.dart';
import '../../models/media_cache_entry.dart';

/// Index over the `cache/` content store.
///
/// Keyed by the server `file_url`, so one set of bytes is stored once no
/// matter how many documents reference it — Frappe dedupes uploads by content
/// hash and hands back the same url for identical bytes.
///
/// Cache state is NON-AUTHORITATIVE. A row whose file is missing is a cache
/// miss, never an error, and callers must treat absence as "re-fetch" rather
/// than "fail". Document deletion never touches this table.
class MediaCacheDao {
  final DatabaseExecutor _db;

  MediaCacheDao(this._db);

  /// Inserts or replaces the entry for [fileUrl].
  ///
  /// Uses INSERT OR REPLACE rather than `ON CONFLICT ... DO UPDATE`, which
  /// needs SQLite >= 3.24 and breaks on Android < 9. No columns need
  /// preserving across an upsert, so REPLACE is the safe choice here.
  Future<void> upsert({
    required String fileUrl,
    required String localPath,
    int? sizeBytes,
    String? mimeType,
    bool isPrivate = true,
    required MediaSource source,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await _db.insert('media_cache', <String, Object?>{
      'file_url': fileUrl,
      'local_path': localPath,
      'size_bytes': sizeBytes,
      'mime_type': mimeType,
      'is_private': isPrivate ? 1 : 0,
      'source': source.wireName,
      'created_at': now,
      'last_accessed_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<MediaCacheEntry?> findByUrl(String fileUrl) async {
    final rows = await _db.query(
      'media_cache',
      where: 'file_url = ?',
      whereArgs: [fileUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return MediaCacheEntry.fromMap(rows.first);
  }

  /// Records a read. Phase 2's LRU eviction consumes this; Phase 1 only
  /// populates it so the policy has real data the day it lands instead of
  /// starting blind. A no-op for an unknown url.
  Future<void> touch(String fileUrl) async {
    await _db.update(
      'media_cache',
      <String, Object?>{
        'last_accessed_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'file_url = ?',
      whereArgs: [fileUrl],
    );
  }

  /// Total bytes across everything with a recorded size. Rows with a NULL
  /// `size_bytes` contribute 0 rather than poisoning the sum — sizes were not
  /// captured before this pipeline existed.
  Future<int> totalBytes() async {
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(size_bytes), 0) AS total FROM media_cache',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  Future<int> deleteAll() => _db.delete('media_cache');
}
