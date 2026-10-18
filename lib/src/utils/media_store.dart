import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/media_store_usage.dart';
import 'attachment_cipher.dart';
import 'attachment_paths.dart';
import 'sdk_log.dart';

/// Root sub-directory under the app documents directory.
const String kAttachmentStoreDir = 'mform_attachments';

/// Staging for picked files that have not been uploaded yet. Owned by
/// `pending_attachments`. NEVER evictable — these are the only copy of the
/// bytes in existence.
const String kOutboxSubDir = 'outbox';

/// Content store keyed by the server `file_url`. Evictable (Phase 2) and wiped
/// on logout. Always re-fetchable, so losing it is never a correctness problem.
const String kCacheSubDir = 'cache';

/// A conservative filename extension: a dot plus 1–10 alphanumerics, nothing
/// else. Anything with a query string, a path separator or punctuation fails,
/// which is the point — see [MediaStore._safeExtensionOf].
final RegExp _safeExtensionPattern = RegExp(r'^\.[A-Za-z0-9]{1,10}$');

const Uuid _uuid = Uuid();

/// Reclaims the local bytes behind an attach value the user discarded or
/// replaced.
///
/// The seam exists because [MediaStore.discardValue] cannot see the queue.
/// A form's field value outlives the column it was saved into — `LocalWriter`
/// rewrites the column to `pending:<id>` inside the save transaction while the
/// open form keeps the raw staged path — so a widget deleting on its own
/// authority can destroy bytes a committed `pending_attachments` row owns.
/// Hosts with a database pass `OfflineRepository.reclaimDiscardedAttachment`,
/// which refuses a referenced file; [MediaStore.discardValue] remains the
/// default for hosts that have no queue to consult.
typedef ReclaimAttachmentFn = Future<void> Function(String? value);

/// Two-directory media store backing the attachment pipeline.
///
/// There is NO transaction spanning the filesystem and SQLite, and this class
/// does not pretend otherwise. Callers order their writes so that every
/// divergence is self-healing: a cache file with no `media_cache` row is
/// harmless orphan bytes, and a row with no file is a cache miss.
class MediaStore {
  static String? _testRoot;

  /// Paths staged in THIS process. Guards the sweep against deleting a pick
  /// that is live in an open form: such a file has no `pending_attachments`
  /// row yet, so a row check alone would classify it as an orphan.
  ///
  /// Entries are never removed. Once a file is saved its row protects it, so
  /// double protection costs nothing and avoids coupling this store to
  /// `LocalWriter`. After a restart the set is empty and those same files are
  /// genuinely orphaned — so they become sweepable exactly when they should.
  static final Set<String> _stagedThisSession = <String>{};

  /// Read-only view of the live-set.
  static Set<String> get stagedThisSession =>
      Set<String>.unmodifiable(_stagedThisSession);

  /// Test seam. `getApplicationDocumentsDirectory()` needs a platform channel
  /// that plain `flutter test` does not provide, and mocking path_provider per
  /// test file is more machinery than one explicit override.
  @visibleForTesting
  static void overrideRootForTest(String? absoluteRoot) {
    _testRoot = absoluteRoot;
    // Paths from a previous root would otherwise protect unrelated files.
    _stagedThisSession.clear();
  }

  static String? _testTempRoot;

  /// Test seam for the OS temp root. Same reason as [overrideRootForTest]:
  /// `getTemporaryDirectory()` needs a platform channel `flutter test` lacks.
  @visibleForTesting
  static void overrideTempRootForTest(String? absoluteRoot) {
    _testTempRoot = absoluteRoot;
  }

  /// The viewer's scratch directory — attachments downloaded only so the
  /// device's default app can open them.
  ///
  /// NOT under [_root]: it is a performance/convenience copy under the OS temp
  /// root, which is why every sweep that walks [_root] misses it. See
  /// [attachmentTempDirName].
  static Future<String> viewerTempDir() async =>
      p.join(await _osTempRoot(), attachmentTempDirName);

  /// The OS temp root, honouring [overrideTempRootForTest].
  ///
  /// The single resolver for it. Two independent `getTemporaryDirectory()` calls
  /// building the same path is how the writer and the wipe drift apart — the
  /// exact shape of the `moveToCache` / `resolve` bug this release also fixes.
  static Future<String> _osTempRoot() async =>
      _testTempRoot ?? (await getTemporaryDirectory()).path;

  /// A path an EXTERNAL app can open for the local attachment at [path].
  ///
  /// A plain file is returned as is. An encrypted one (see [AttachmentCipher])
  /// is decrypted into [viewerTempDir] — the scratch directory already used for
  /// downloaded attachments, which [clearAll] (logout) and [clearCache] wipe —
  /// because another app cannot read the SDK's ciphertext. The copy is keyed
  /// by a digest of [path] so repeated opens reuse one file.
  ///
  /// Throws [AttachmentDecryptionException] when the file cannot be decrypted.
  static Future<String> plainPathForViewer(String path) async {
    if (!await AttachmentCipher.isEncryptedFile(path)) return path;
    final bytes = await AttachmentCipher.readPlainBytes(path);
    final digest = sha256
        .convert(utf8.encode(path))
        .toString()
        .substring(0, 16);
    final target = File(
      p.join(await viewerTempDir(), 'dec_$digest', p.basename(path)),
    );
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  /// Absolute path of the camera-capture marker.
  ///
  /// Deliberately in the temp ROOT rather than inside [viewerTempDir]: that is
  /// where it has always been written, and moving it would orphan a marker left
  /// by a version being upgraded from. See [cameraCaptureMarkerFileName].
  static Future<String> captureMarkerPath() async =>
      p.join(await _osTempRoot(), cameraCaptureMarkerFileName);

  /// Total bytes held by the viewer scratch cache.
  static Future<int> viewerTempBytes() async {
    var total = 0;
    try {
      // Resolving the path is itself fallible: `getTemporaryDirectory()` needs
      // a platform channel, which a plain `flutter test` (no binding) and a
      // stripped-down embedder both lack. Usage reporting must degrade to "0",
      // never take the caller down.
      final dir = Directory(await viewerTempDir());
      if (!await dir.exists()) return 0;
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          total += await e.length();
        } catch (err, st) {
          sdkLog('MediaStore.viewerTempBytes: stat(${e.path}) — $err\n$st');
        }
      }
    } catch (e, st) {
      sdkLog('MediaStore.viewerTempBytes failed — $e\n$st');
    }
    return total;
  }

  /// Deletes the viewer scratch cache outright.
  ///
  /// Unconditional and NOT reference-counted, which is precisely why it is not
  /// part of [sweepOrphans]: that sweep decides what to delete from
  /// `pending_attachments` references, and nothing ever references a file here,
  /// so every one of them would read as orphaned. Including them would make a
  /// reference-based sweep into a blanket delete wearing a sweep's name.
  ///
  /// Called from [clearAll] (and therefore logout) and from [clearCache].
  /// Deleting a file an external viewer still has open is safe on POSIX — the
  /// reader's descriptor stays valid after the unlink — so an explicit,
  /// user-initiated clear does not need to wait for viewers to close.
  static Future<void> clearViewerTempCache() async {
    try {
      // Inside the try on purpose: `getTemporaryDirectory()` needs a platform
      // channel. A logout must not fail because the scratch directory could not
      // be located — the store wipe that precedes it is the load-bearing half.
      final dir = Directory(await viewerTempDir());
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e, st) {
      sdkLog('MediaStore.clearViewerTempCache failed — $e\n$st');
    }
  }

  static Future<String> _root() async {
    final base = _testRoot ?? (await getApplicationDocumentsDirectory()).path;
    return p.join(base, kAttachmentStoreDir);
  }

  /// Copies [source] into `outbox/<id>/<original filename>` and returns the
  /// durable path.
  ///
  /// The file keeps the name the USER picked; uniqueness comes from the
  /// generated parent directory. That matters because the original filename
  /// cannot travel any other way — it does not fit through the field's
  /// `onChanged`, and renaming to `<uuid><ext>` (the previous behaviour) lost
  /// it permanently, so every upload landed server-side as an opaque uuid.
  ///
  /// When `FrappeSDK(encryptAttachments: true)` is in force the staged file is
  /// AES-256-GCM ciphertext (see [AttachmentCipher]) and a picker scratch copy
  /// of [source] is deleted afterwards (see [_deletePickerScratch]). The name
  /// and extension stay the user's either way.
  static Future<String> stageToOutbox(
    File source, {
    String Function()? nameGen,
  }) async {
    final base = nameGen?.call() ?? _uuid.v4();
    final dir = Directory(p.join(await _root(), kOutboxSubDir, base));
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = p.join(dir.path, p.basename(source.path));
    // Register BEFORE the file exists. The reverse order leaves a window in
    // which a sweep could observe a freshly-created file that has neither a
    // pending_attachments row nor a live-set entry, and delete a pick that is
    // about to become live.
    _stagedThisSession.add(dest);
    if (!AttachmentCipher.encryptsNewFiles) {
      await source.copy(dest);
      return dest;
    }
    // Encrypted staging. The bytes are encrypted in memory and land through a
    // temp file + rename, so no plain copy is ever written under outbox/. The
    // temp path is registered too, so a concurrent sweep cannot delete it
    // between the write and the rename.
    _stagedThisSession.add(AttachmentCipher.tempPathFor(dest));
    await AttachmentCipher.writeEncrypted(dest, await source.readAsBytes());
    await _deletePickerScratch(source);
    return dest;
  }

  /// Deletes [source] after an encrypted stage, but ONLY when it is a picker's
  /// scratch copy.
  ///
  /// `image_picker` and `file_picker` hand back a COPY in the app's own temp or
  /// cache directory. Left there, it is a plain duplicate of the attachment the
  /// outbox has just encrypted. A path anywhere else — the gallery, Downloads,
  /// a host-supplied file, this store itself — is the user's or the host's,
  /// and is never touched.
  ///
  /// The roots are the path_provider temp directory (Android: the app cache
  /// dir, where both pickers write) and, on iOS, the app's sandboxed `tmp/`
  /// (`Directory.systemTemp`), where `image_picker` writes. Containment is
  /// canonical, as in [isStagedPath]. Best-effort: failing to delete never
  /// fails the pick; the OS reclaims temp files eventually.
  static Future<void> _deletePickerScratch(File source) async {
    try {
      final src = p.canonicalize(source.path);
      final storeRoot = p.canonicalize(await _root());
      if (src == storeRoot || p.isWithin(storeRoot, src)) return;
      final roots = <String>[
        await _osTempRoot(),
        if (_testTempRoot == null && Platform.isIOS) Directory.systemTemp.path,
      ];
      final inScratch = roots.any((r) => p.isWithin(p.canonicalize(r), src));
      if (!inScratch) return;
      if (await source.exists()) await source.delete();
    } catch (e, st) {
      sdkLog('MediaStore: could not delete picker scratch copy — $e\n$st');
    }
  }

  /// Deterministic cache location for [fileUrl].
  ///
  /// Hashing the url keeps the name filesystem-safe and collision-free while
  /// staying reproducible, so a lookup can find the path without consulting
  /// the index. [sourcePath] supplies the extension when the url has none
  /// (e.g. a `download_file` proxy url that carries the name in its query).
  /// PURE: computes a path and creates nothing. Asking where a file would live
  /// must not resurrect a store that was just wiped — writers call
  /// [_ensureParent] themselves.
  static Future<String> cachePathFor(
    String fileUrl, {
    String? sourcePath,
  }) async {
    final dirPath = p.join(await _root(), kCacheSubDir);
    final digest = sha256.convert(utf8.encode(fileUrl)).toString();
    var ext = _safeExtensionOf(fileUrl);
    if (ext.isEmpty && sourcePath != null) ext = _safeExtensionOf(sourcePath);
    return p.join(dirPath, '$digest$ext');
  }

  /// A `.ext` from [pathOrUrl] that is safe to put in a filename, or `''`.
  ///
  /// `p.extension` alone is NOT safe here, because a url is not a path: it takes
  /// everything after the last dot of the last segment, query string included.
  /// For the `download_file` / cloud-proxy shape this class already documents —
  /// `…/multi_cloud_storage.download?file=survey.pdf&key=<signature>` — that is
  /// `.pdf&key=<signature>`, so a 300-character signed key produced a 373-char
  /// filename against a 255-byte `NAME_MAX`. The write threw `ENAMETOOLONG`,
  /// [MediaResolver.resolve]'s catch-all swallowed it, no `media_cache` row was
  /// written, and the attachment re-downloaded on every single view — forever,
  /// while the bytes it did fetch were never cached.
  ///
  /// Rejecting rather than truncating is deliberate: a truncated extension is
  /// still wrong (`.pdf&key=AAA…`), and the extension is cosmetic here — the
  /// digest alone is unique and the `media_cache` row carries the real name. An
  /// empty result yields a bare `<digest>`, which is correct and collision-free.
  ///
  /// Mirrors `_safeExtension` in `attach_field.dart`, which guards the same
  /// hazard on the display-filename path.
  static String _safeExtensionOf(String pathOrUrl) {
    final ext = p.extension(pathOrUrl);
    return _safeExtensionPattern.hasMatch(ext) ? ext.toLowerCase() : '';
  }

  /// True only when [path] is a file inside `outbox/`.
  ///
  /// CANONICAL containment, not a string prefix: `p.canonicalize` resolves
  /// `..` segments, and `p.isWithin` rejects a similarly named sibling such as
  /// `outbox_old/`. A prefix match would admit both, and callers use this to
  /// decide whether to DELETE a file — a host may legitimately point a field at
  /// `/sdcard/DCIM/holiday.jpg`, and destroying that would be unforgivable.
  ///
  /// Returns false for the outbox root itself: it is a directory, not a staged
  /// file.
  static Future<bool> isStagedPath(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return false;
    final outbox = p.canonicalize(p.join(await _root(), kOutboxSubDir));
    return p.isWithin(outbox, p.canonicalize(trimmed));
  }

  /// Creates the parent directory of [filePath] if needed.
  static Future<void> _ensureParent(String filePath) async {
    final parent = Directory(p.dirname(filePath));
    if (!await parent.exists()) await parent.create(recursive: true);
  }

  /// Moves a staged file into the cache under [fileUrl]'s key.
  ///
  /// Returns **the destination path actually used**, or null when neither
  /// source nor destination exists — cache population must never silently claim
  /// success.
  ///
  /// Returning the path rather than a bool is load-bearing. [cachePathFor]
  /// borrows the extension from [stagedPath] when [fileUrl] carries none, so the
  /// destination is NOT derivable from [fileUrl] alone. A caller that recomputed
  /// it without the source would name `<digest>` while the bytes sit at
  /// `<digest><ext>` — a `media_cache` row pointing at a file that was never
  /// written, which reads as a permanent cache miss and strands the real bytes
  /// where no sweep reclaims them (`sweepOrphans` walks `outbox/` only).
  ///
  /// IDEMPOTENT: when the destination already exists this reports success even
  /// if the staged file is gone, so an interrupted upload resumes without
  /// re-uploading.
  static Future<String?> moveToCache(String stagedPath, String fileUrl) async {
    final dest = await cachePathFor(fileUrl, sourcePath: stagedPath);
    final destFile = File(dest);
    if (await destFile.exists()) {
      // Already moved by a previous attempt; clean up any staged leftover.
      await deleteOutboxCopy(stagedPath);
      return dest;
    }
    final src = File(stagedPath);
    if (!await src.exists()) return null;
    await _ensureParent(dest);
    try {
      await src.rename(dest);
      return dest;
    } catch (e, st) {
      // `rename` fails across filesystems (Android app-private vs external).
      sdkLog(
        'MediaStore.moveToCache: rename failed, falling back to copy — $e\n$st',
      );
      try {
        await src.copy(dest);
        await deleteOutboxCopy(stagedPath);
        return dest;
      } catch (e2, st2) {
        sdkLog('MediaStore.moveToCache: copy fallback failed — $e2\n$st2');
        return null;
      }
    }
  }

  /// Best-effort delete of a staged copy. Never throws.
  ///
  /// Also prunes the per-pick parent directory, which would otherwise
  /// accumulate one empty folder per attachment forever.
  static Future<void> deleteOutboxCopy(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
      final parent = f.parent;
      // Only ever prune a directory that sits directly under outbox/, so a
      // caller passing an arbitrary path can never delete something else.
      final outbox = p.join(await _root(), kOutboxSubDir);
      if (p.dirname(parent.path) == outbox && await parent.exists()) {
        final remaining = await parent.list().isEmpty;
        if (remaining) await parent.delete();
      }
    } catch (e, st) {
      sdkLog('MediaStore.deleteOutboxCopy($path) failed — $e\n$st');
    }
  }

  /// Deletes the staged file behind a field value that is being REPLACED.
  ///
  /// A no-op unless the value is a path inside `outbox/`, so a `pending:<id>`
  /// marker, a server url, a cache path and a host-supplied gallery path are
  /// all left alone.
  ///
  /// No database check is made here, and the reason is narrower than it looks.
  /// A saved attachment's COLUMN holds `pending:<id>`, never a path —
  /// `LocalWriter` swaps the path for the marker inside the save transaction,
  /// and a failed enqueue rolls that transaction back. So a *column* holding a
  /// raw staged path has by construction never been saved.
  ///
  /// That does NOT extend to a value handed in by a form. A field keeps what
  /// the user picked (`hasInteractedByUser` pins it against a later widget
  /// value), so once the form has been saved and left open it still offers the
  /// raw path the column no longer holds — and deleting then destroys the only
  /// copy of bytes a committed `pending_attachments` row owns, blocking the
  /// document on a file that no longer exists. UI callers therefore go through
  /// [ReclaimAttachmentFn], wired to
  /// `OfflineRepository.reclaimDiscardedAttachment`, which consults the queue
  /// first. Call this directly only where the value is known not to be a form's.
  /// BEST-EFFORT and never throws. Reclaiming bytes must not be able to fail
  /// the user's action: a failure here leaves an orphan, which the sweep
  /// reclaims later, whereas a thrown exception would abort the caller
  /// mid-way — leaving the field un-cleared while the user believes otherwise.
  static Future<void> discardReplacedValue(String? previousValue) async {
    final v = previousValue?.trim();
    if (v == null || v.isEmpty) return;
    try {
      if (!await isStagedPath(v)) return;
      await deleteOutboxCopy(v);
    } catch (e, st) {
      sdkLog('MediaStore.discardReplacedValue($v) failed — $e\n$st');
    }
  }

  /// Reclaims the local bytes behind a value the user has DISCARDED.
  ///
  /// Identical to [discardReplacedValue] — a staged file is deleted, anything
  /// else is left alone. Named separately because the two call sites mean
  /// different things: one replaces, one removes, and a reader should not have
  /// to infer which from the argument.
  ///
  /// Clearing the FIELD is the caller's job, and deleting the queued row is
  /// the save path's (`LocalWriter` drops it when the field arrives empty).
  /// A synced file is left on the server, matching delete and re-pick.
  static Future<void> discardValue(String? value) =>
      discardReplacedValue(value);

  /// Files under `outbox/`, paired with their size. Absent directory -> empty.
  static Future<List<MapEntry<String, int>>> _outboxFiles() async {
    final out = <MapEntry<String, int>>[];
    final dir = Directory(p.join(await _root(), kOutboxSubDir));
    if (!await dir.exists()) return out;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      try {
        out.add(MapEntry(e.path, await e.length()));
      } catch (err, st) {
        sdkLog('MediaStore._outboxFiles: stat(${e.path}) failed — $err\n$st');
      }
    }
    return out;
  }

  /// True when a staged file is reclaimable: no queued row references it and it
  /// was not staged in this session.
  ///
  /// Both guards are exact. There is no age heuristic, so a pick sitting in an
  /// open form is never at risk.
  static bool _isOrphan(String path, Set<String> referencedPaths) =>
      !referencedPaths.contains(path) && !_stagedThisSession.contains(path);

  /// Usage snapshot. Reads only — never deletes.
  ///
  /// [referencedPaths] comes from `PendingAttachmentDao.referencedLocalPaths()`;
  /// passing it in keeps this class off the database.
  static Future<MediaStoreUsage> usage(Set<String> referencedPaths) async {
    var outboxBytes = 0;
    var orphanBytes = 0;
    var orphanCount = 0;
    for (final f in await _outboxFiles()) {
      outboxBytes += f.value;
      if (_isOrphan(f.key, referencedPaths)) {
        orphanBytes += f.value;
        orphanCount++;
      }
    }

    var cacheBytes = 0;
    final cacheDir = Directory(p.join(await _root(), kCacheSubDir));
    if (await cacheDir.exists()) {
      await for (final e in cacheDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (e is! File) continue;
        try {
          cacheBytes += await e.length();
        } catch (err, st) {
          sdkLog('MediaStore.usage: stat(${e.path}) failed — $err\n$st');
        }
      }
    }

    return MediaStoreUsage(
      outboxBytes: outboxBytes,
      cacheBytes: cacheBytes,
      orphanBytes: orphanBytes,
      orphanCount: orphanCount,
      viewerTempBytes: await viewerTempBytes(),
    );
  }

  /// Deletes every orphaned staged file and returns the bytes reclaimed.
  ///
  /// NEVER THROWS: a per-file failure is logged, not counted, and the sweep
  /// continues. Only `outbox/` is walked — `cache/` is out of scope.
  ///
  /// The CALLER must not pass an empty [referencedPaths] when the query that
  /// produced it failed: an empty set would make every staged file look
  /// reclaimable. See `FrappeSDK.sweepOrphanedMedia`.
  static Future<int> sweepOrphans(Set<String> referencedPaths) async {
    var freed = 0;
    for (final f in await _outboxFiles()) {
      if (!_isOrphan(f.key, referencedPaths)) continue;
      try {
        final file = File(f.key);
        // Vanished between listing and deleting (e.g. a concurrent push moved
        // it into cache/). Not an error, and not bytes we freed.
        if (!await file.exists()) continue;
        await deleteOutboxCopy(f.key);
        if (!await file.exists()) freed += f.value;
      } catch (e, st) {
        sdkLog('MediaStore.sweepOrphans: delete(${f.key}) failed — $e\n$st');
      }
    }
    return freed;
  }

  /// Removes the `cache/` subtree ONLY.
  ///
  /// Never touches `outbox/`. Cached bytes are a performance copy of server
  /// media and are always re-fetchable; staged files are the only copy of an
  /// attachment that has not uploaded yet. A "clear cache" operation must not
  /// cross that line — see [clearAll] for the wipe that deliberately does.
  static Future<void> clearCache() async {
    final dir = Directory(p.join(await _root(), kCacheSubDir));
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e, st) {
      sdkLog('MediaStore.clearCache failed — $e\n$st');
    }
    // The viewer scratch cache is reclaimed here too, because
    // [MediaStoreUsage.totalBytes] COUNTS it: a host that shows that number and
    // wires a "Clear cached media" control to this method would otherwise leave
    // the user tapping a button that does not move the figure they were shown.
    // Both directories hold the same kind of thing — a re-fetchable copy of
    // server media — so both belong to the same clear.
    await clearViewerTempCache();
  }

  /// Removes BOTH directories. Used by logout and wipe: cached media must not
  /// outlive the data it belongs to on a shared device.
  ///
  /// This also clears `outbox/`, which holds the only copy of any un-uploaded
  /// attachment — callers must treat it as destructive.
  static Future<void> clearAll() async {
    _stagedThisSession.clear();
    final dir = Directory(await _root());
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e, st) {
      sdkLog('MediaStore.clearAll failed — $e\n$st');
    }
    // The viewer scratch cache lives under the OS temp root, NOT under
    // [_root], so deleting the line above never touched it. That left decrypted
    // copies of private attachments on disk after `logout(clearDatabase: true)`
    // — which is the one call whose entire purpose is that they are gone.
    await clearViewerTempCache();
    // Same root, same reason. The marker names the field that launched the
    // camera; left behind, an interrupted capture could be handed to a field in
    // the NEXT session, on a shared device a different user's. Its own staleness
    // window bounds that but does not close it — a logout inside the window
    // leaves it live.
    try {
      final marker = File(await captureMarkerPath());
      if (await marker.exists()) await marker.delete();
    } catch (e, st) {
      sdkLog('MediaStore.clearAll: capture marker — $e\n$st');
    }
  }
}
