import 'dart:io';

import '../database/daos/media_cache_dao.dart';
import '../models/media_cache_entry.dart';
import '../utils/attachment_paths.dart';
import '../utils/media_store.dart';
import '../utils/sdk_log.dart';

/// Fetches the bytes behind a server `file_url`.
///
/// Returns null on any failure — a media fetch must never break form
/// rendering, so the resolver degrades to a placeholder instead.
typedef MediaFetchFn = Future<List<int>?> Function(String fileUrl);

/// Resolves a stored attach-field value to a local path for DISPLAY, or null
/// when it cannot be shown (offline miss, unknown marker, failed fetch).
///
/// [MediaResolver.resolve] satisfies this signature, so hosts pass
/// `resolver.resolve` directly. Field widgets depend on this function rather
/// than on [MediaResolver] itself: it keeps the UI layer off the DAO/filesystem
/// stack, which matters because widget tests run in a fake-async zone where
/// real sqflite and dart:io futures never complete.
typedef ResolveMediaFn =
    Future<String?> Function(String value, {Map<int, String>? pendingPaths});

/// Ceiling on a single DOWNLOADED media body, matching Frappe's default
/// `max_file_size` (25 MB) rather than the 10 MB pick guard.
///
/// The two limits differ deliberately: [kDefaultMaxAttachmentBytes] bounds what
/// this device may CREATE, while this bounds what it will accept from a server
/// that has already accepted it — a Desk user can legitimately attach something
/// larger than the mobile pick guard allows, and refusing to display it would be
/// a worse failure than the download costing memory.
const int kDefaultMaxMediaFetchBytes = 25 * 1024 * 1024;

/// Resolves an attach-field value to a local path for DISPLAY.
///
/// The stored field value is never modified here. Display resolution must not
/// leak into the marker / `inlinePayload` contract: a `pending:<id>` value
/// stays a marker until the push pipeline uploads it and writes back the real
/// `file_url`.
class MediaResolver {
  final MediaCacheDao cache;
  final MediaFetchFn fetch;
  final bool Function() isOnline;

  /// Ceiling on a fetched body, inclusive. See [kDefaultMaxMediaFetchBytes].
  ///
  /// This is the SECOND half of the download bound, not the whole of it. By the
  /// time [fetch] returns, its body is already in memory — so this stops an
  /// oversized download being written to disk and indexed in `media_cache`
  /// (where it would be re-read on every view), but it cannot prevent the
  /// allocation. Bounding memory has to happen inside the injected fetcher,
  /// which is the only place that sees the response before it is buffered.
  final int maxFetchBytes;

  MediaResolver({
    required this.cache,
    required this.fetch,
    required this.isOnline,
    this.maxFetchBytes = kDefaultMaxMediaFetchBytes,
  });

  /// Resolution order:
  ///
  ///   `pending:<id>` -> staged path (this device, not yet uploaded)
  ///   `/abs/device/path` -> itself, if the file exists (never fetched)
  ///   `<file_url>`   -> cache hit  -> local path
  ///                  -> miss + online  -> fetch, store, return
  ///                  -> miss + offline -> null (caller shows a placeholder)
  ///
  /// A marker is never fetched over HTTP: it is local identity, not a url.
  Future<String?> resolve(
    String value, {
    Map<int, String>? pendingPaths,
  }) async {
    final v = value.trim();
    if (v.isEmpty) return null;

    // Any `pending:` value resolves from the staging map or not at all.
    // Falling through to the network for a malformed marker would turn a
    // local id into a request path.
    if (v.startsWith(kPendingMarkerPrefix)) {
      final markerId = parsePendingMarkerId(v);
      if (markerId == null) return null;
      return pendingPaths?[markerId];
    }

    // A device filesystem path is not a server reference and can never be
    // fetched. Between pick and save the field holds exactly that — a staged
    // path — and treating it as a url prepends the base url and issues a
    // guaranteed 404. In offline mode that is precisely the network call the
    // mode exists to avoid.
    if (isLocalAttachmentPath(v)) {
      try {
        return await File(v).exists() ? v : null;
      } catch (e, st) {
        sdkLog('MediaResolver.resolve: stat($v) failed — $e\n$st');
        return null;
      }
    }

    try {
      final hit = await cache.findByUrl(v);
      if (hit != null && await File(hit.localPath).exists()) {
        await cache.touch(v);
        return hit.localPath;
      }
      // A row whose file is gone is a MISS, not an error: cache content is
      // non-authoritative and can always be re-fetched.
      if (!isOnline()) return null;

      final bytes = await fetch(v);
      if (bytes == null || bytes.isEmpty) return null;
      if (bytes.length > maxFetchBytes) {
        sdkLog(
          'MediaResolver.resolve($v): ${bytes.length} bytes exceeds the '
          '$maxFetchBytes byte cap — not cached',
        );
        return null;
      }

      final dest = await MediaStore.cachePathFor(v);
      final file = File(dest);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      await cache.upsert(
        fileUrl: v,
        localPath: dest,
        sizeBytes: bytes.length,
        source: MediaSource.downloaded,
      );
      return dest;
    } catch (e, st) {
      sdkLog('MediaResolver.resolve($v) failed — $e\n$st');
      return null;
    }
  }
}
