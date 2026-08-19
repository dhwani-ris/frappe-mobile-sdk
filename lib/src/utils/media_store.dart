import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/media_store_usage.dart';
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

const Uuid _uuid = Uuid();

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
    await source.copy(dest);
    return dest;
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
    var ext = p.extension(fileUrl);
    if (ext.isEmpty && sourcePath != null) ext = p.extension(sourcePath);
    return p.join(dirPath, '$digest$ext');
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
  /// No database check is needed, and that is not a shortcut: a saved
  /// attachment's column holds `pending:<id>`, never a path — `LocalWriter`
  /// swaps the path for the marker inside the save transaction, and a failed
  /// enqueue rolls that transaction back. So a column holding a raw staged path
  /// has by construction never been saved and has no `pending_attachments` row.
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
  }
}
