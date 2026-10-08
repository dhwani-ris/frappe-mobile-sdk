// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:open_filex/open_filex.dart';
import '../../../services/media_resolver.dart';
import '../../../sync/attachment_error_classifier.dart';
import '../../../utils/attachment_paths.dart';
import '../../../utils/media_store.dart';
import '../../../utils/attachment_pick.dart';
import '../../../utils/sdk_log.dart';
import 'base_field.dart';
import 'field_helpers.dart';
// Reuse the shared full-screen zoomable image viewer (showFullScreenImage /
// showFullScreenImageProvider) so image attachments open exactly like
// ImageField previews, with the same auth headers.
import 'image_field.dart';

/// Normalises the result of `FilePicker.pickFiles()` across the file_picker
/// major versions this SDK supports (`>=11.0.2 <14.0.0`).
///
/// The shape changed in 12.0.0, without a source-compatible bridge:
///   * **11.x** returns a nullable `FilePickerResult?` whose `.files` is the
///     selection; `null` means the user cancelled.
///   * **12.x / 13.x** return `List<PlatformFile>` directly; an empty list is
///     cancel.
///
/// The SELECTION SEMANTICS changed with it, which matters at the call site:
/// 11.x defaults `allowMultiple` to `false`; 12.x flips that default to `true`
/// and deprecates the parameter, and 13.x removes it outright, moving
/// single-select to a separate `pickFile()`. So from 12.x on `pickFiles()` is
/// multi-select whatever the caller intended, and anything in this range must
/// be prepared for MORE THAN ONE file.
///
/// Dart has no conditional compilation, so one source file cannot statically
/// typecheck against both. This function is the SINGLE point where the
/// difference is absorbed: the argument is typed `Object?` so it accepts either
/// static type, and every caller sees one shape. Widening the constraint
/// WITHOUT this would compile here and fail at whichever end the consumer
/// happens to resolve.
///
/// Deliberately tolerant: anything unrecognised reads as "no selection" rather
/// than throwing, because a picker that cannot be interpreted must not take the
/// form down — the field simply stays empty, which is the cancel path.
List<Object?> pickedFilesOf(Object? raw) {
  if (raw == null) return const [];
  if (raw is List) return raw;
  try {
    final files = (raw as dynamic).files;
    return files is List ? files : const [];
  } on NoSuchMethodError {
    // Not a shape this SDK knows. Narrowed to this ONE exception type so a
    // genuine fault in a real picker surfaces rather than being reclassified as
    // "user cancelled". It is not narrowed by ORIGIN — a NoSuchMethodError
    // raised inside a real `.files` getter would land here too. Accepted
    // because every supported `.files` is a plain field access, so there is no
    // getter body for one to come from.
    return const [];
  }
}

/// The one filesystem path this field should adopt from a `pickFiles()` result,
/// or `null` for "nothing to attach".
///
/// Exists as a separate function because the decision it encodes is NOT
/// obvious and was got wrong once. An `Attach` docfield holds a single file,
/// but `pickFiles()` can hand back several: 12.x and 13.x removed
/// `allowMultiple`, so the dialog is always multi-select there regardless of
/// how it is invoked. Taking `.single` — which is what this code did — threw
/// `StateError` the moment a user selected two files, and the call site's
/// catch-all turned that into a silent "attach failed". So: FIRST, not single.
///
/// Splitting it out is what makes that testable at all. The call site is a
/// button callback that invokes the STATIC `FilePicker.pickFiles()`, and a fake
/// platform cannot be written to typecheck against both majors — the same
/// reason [pickedFilesOf] is duck-typed. A pure function over the result shape
/// is the only seam a cross-version test can reach.
String? pickedPathOf(Object? raw) {
  final files = pickedFilesOf(raw);
  if (files.isEmpty) return null;
  try {
    final path = (files.first as dynamic).path;
    return path is String ? path : null;
  } on NoSuchMethodError {
    // An entry that is not a PlatformFile: unusable, same as cancel.
    return null;
  }
}

/// Dedicated subdirectory (under the OS temp dir) holding attachments that were
/// downloaded so an external app could open them. Keeping them in one folder
/// instead of loose in the temp root makes the cache identifiable and lets the
/// OS reclaim it as a unit.
///
/// Declared in `utils/attachment_paths.dart` so `MediaStore` can wipe and
/// measure the directory without importing a widget file.

/// File name used to cache the attachment at [url] inside
/// [attachmentTempDirName].
///
/// The name is the SHA-1 of the FULL [url], so two attachments that happen to
/// share a basename (two different `report.pdf`s) can never overwrite each
/// other — the old code named the temp file after the basename alone and showed
/// the user STALE bytes from the earlier download. It is also deterministic:
/// re-opening the same attachment reuses (and overwrites) the same file instead
/// of littering the cache with one copy per tap.
///
/// [fileName] is the basename of the stored field value and is only used to
/// recover the extension, which [OpenFilex] needs to pick a handler app.
@visibleForTesting
String attachmentTempFileName(String url, String fileName) {
  final digest = sha1.convert(utf8.encode(url)).toString();
  return '$digest${_cacheExtension(url, fileName)}';
}

/// Extension to preserve on the cached file, `''` when none can be trusted.
///
/// [fileName] (the stored value's basename) wins because a Frappe
/// `download_file` proxy URL carries the real name only inside its query
/// string; the URL path is the fallback. Anything that is not a short
/// alphanumeric extension is dropped so nothing outside the hashed name can be
/// injected into the path.
String _cacheExtension(String url, String fileName) {
  String urlPath;
  try {
    urlPath = Uri.parse(url).path;
  } catch (_) {
    urlPath = url;
  }
  for (final candidate in [fileName, urlPath]) {
    final ext = _extensionOf(candidate.trim());
    if (_safeExtension.hasMatch(ext)) return ext.toLowerCase();
  }
  return '';
}

/// Trailing `.ext` of [name], or `''` when it has none.
String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  if (dot < name.lastIndexOf('/')) return '';
  return name.substring(dot);
}

final RegExp _safeExtension = RegExp(r'^\.[A-Za-z0-9]{1,10}$');

/// Raised when an attachment is bigger than
/// [_AttachViewButtonState.maxDownloadBytes]. A dedicated type keeps the
/// user-facing message distinct from a generic transport failure.
class _AttachmentTooLarge implements Exception {
  const _AttachmentTooLarge();
}

/// Widget for Attach field type.
/// When [uploadFile] is set, picks upload to server first and store file_url; otherwise stores local path.
/// When a value is present a View/Open action is shown: image attachments open
/// in a full-screen zoomable viewer, other files are downloaded (with auth via
/// [imageHeaders]) to a temp path and opened in the device's default app.
/// For /private/files/ and /files/, uses the Frappe download_file API and
/// [imageHeaders]/[fileUrlBase] for auth (mirrors ImageField).
class AttachField extends BaseField {
  /// Surfaces [message] to the user. `_AttachViewButtonState` has its own
  /// `_showError`, but that lives on the download button's State and is not
  /// reachable from [buildField] — hence this static twin.
  ///
  /// Takes a [ScaffoldMessengerState] rather than a [BuildContext]: callers are
  /// past an `await`, and resolving from a context after an async gap is what
  /// `use_build_context_synchronously` warns about. Capture before the await.
  static void _notify(ScaffoldMessengerState messenger, String message) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  final Future<String?> Function(File file)? uploadFile;

  /// Base URL of the Frappe server, used to resolve relative file paths into
  /// absolute, authenticated download URLs. Optional for backward-compat.
  final String? fileUrlBase;

  /// Auth headers (e.g. from [FrappeClient.requestHeaders]) so private file URLs
  /// can be fetched. Optional for backward-compat.
  final Map<String, String>? imageHeaders;

  /// Synchronous last-known connectivity. When it returns false (offline) the
  /// picked file is kept as a durable local path for save-time queueing instead
  /// of being uploaded inline. Null → treated as online (upload attempted).
  final bool Function()? isOnline;

  /// Map of `pending_attachments.id` → durable local file path, used to resolve
  /// a `pending:<id>` field value (an offline-picked file not yet uploaded)
  /// for the filename label and View/Open action. Display-only.
  final Map<int, String>? pendingAttachmentPaths;

  /// HTTP client used to download a non-image attachment before handing it to
  /// the device's default app. Optional: when null a short-lived client is
  /// created per download and closed afterwards (the pre-existing behaviour).
  /// A client passed in here is owned by the caller and is never closed by this
  /// widget. Exists so the download path can be exercised in tests.
  final http.Client? httpClient;

  /// Resolves a field value to a LOCAL file for viewing: a cache hit, or a
  /// download that is stored in the cache on the way through so the next view
  /// works offline.
  ///
  /// Optional and additive — hosts that wire nothing keep the previous
  /// behaviour, where every open re-downloads to a temp path. Display-only:
  /// it never changes the stored value.
  ///
  /// A function rather than a [MediaResolver] so this widget stays off the
  /// DAO/filesystem stack; pass `myResolver.resolve`.
  final ResolveMediaFn? mediaResolver;

  /// Returns true when the SDK is in offline-first mode.
  ///
  /// When it does, a pick is ALWAYS staged and queued rather than uploaded
  /// inline, whatever the connectivity — offline-first promises that data entry
  /// never blocks on the network, and an inline upload would also put the
  /// attachment outside the push gate and the media cache. Null is treated as
  /// "not offline mode", preserving the previous behaviour.
  final bool Function()? isOfflineMode;

  /// Reclaims the bytes behind a value this field discards or replaces.
  ///
  /// Defaults to [MediaStore.discardValue], which deletes any staged file on
  /// sight. Hosts with a database wire
  /// `OfflineRepository.reclaimDiscardedAttachment` instead — see
  /// [ReclaimAttachmentFn] for why the field's own value is not enough to
  /// decide.
  final ReclaimAttachmentFn reclaimAttachment;

  const AttachField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.uploadFile,
    this.fileUrlBase,
    this.imageHeaders,
    this.isOnline,
    this.pendingAttachmentPaths,
    this.httpClient,
    this.mediaResolver,
    this.isOfflineMode,
    this.reclaimAttachment = MediaStore.discardValue,
  });

  static const Set<String> _imageExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  };

  /// Only Frappe server file paths or full URLs are treated as server URLs.
  /// Local absolute paths (/storage/..., /data/..., /home/..., etc.) are NOT
  /// server URLs. Mirrors ImageField._isServerUrl.
  bool _isServerUrl(String? path) {
    if (path == null || path.isEmpty) return false;
    final p = path.trim();
    if (p.startsWith('http://') || p.startsWith('https://')) return true;
    if (p.startsWith('/files/') || p.startsWith('/private/files/')) return true;
    if (p.startsWith('/api/method/')) return true;
    return false;
  }

  /// Display URL for a stored attach value.
  ///
  /// Delegates to [frappeFileFetchUrl] — this used to be a private copy of that
  /// logic, one of three. `/private/files/` has to route through
  /// `download_file` to carry auth, so a drift between the copies was a
  /// private-file 404. Pinned by `attachment_paths_test.dart`.
  String? _fullFileUrl(String? path) => frappeFileFetchUrl(path, fileUrlBase);

  /// True when the stored value points at an image (by extension). Query strings
  /// are stripped first so URLs like `.../file.png?token=...` still match.
  bool _isImage(String path) {
    var lower = path.trim().toLowerCase();
    final q = lower.indexOf('?');
    if (q >= 0) lower = lower.substring(0, q);
    return _imageExtensions.any(lower.endsWith);
  }

  @override
  Widget buildField(BuildContext context) {
    String? filePath = value?.toString();

    return FormBuilderField<String>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('attach_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: filePath,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      builder: (FormFieldState<String> fieldState) {
        // BaseField.build (the enclosing widget) already renders the
        // external label with required-asterisk + translation. The inline
        // Padding(Text(field.label)) that used to live here was a
        // second copy that skipped the asterisk — removed for visual
        // consistency with text/numeric/etc field widgets.
        // `hasInteractedByUser` is the ONLY thing that distinguishes "the
        // user cleared this" from "never touched". Trusting fieldState.value
        // alone made a discard work but broke a value arriving AFTER the first
        // build (an async document load): initialValue applies once, the
        // field's key is stable so its State survives the rebuild, and the new
        // widget value was ignored. Falling back unconditionally to the widget
        // value — the previous behaviour — made an explicit clear impossible
        // to represent instead. Neither alone is correct.
        final current = liveAttachmentValue(
          hasInteractedByUser: fieldState.hasInteractedByUser,
          fieldValue: fieldState.value,
          widgetValue: filePath,
        );
        final hasValue = current != null && current.isNotEmpty;
        // Resolve a `pending:<id>` marker to its durable local file (display
        // only; stored value stays the marker). Server URLs / local paths pass
        // through. Null => an offline pick whose file isn't resolvable yet.
        final displaySource = attachmentDisplaySource(
          current,
          pendingAttachmentPaths,
        );
        final isPendingUnresolved =
            hasValue &&
            parsePendingMarkerId(current) != null &&
            displaySource == null;
        final isServer = displaySource != null && _isServerUrl(displaySource);
        final isLocalFile = displaySource != null && !isServer;
        final isImage = displaySource != null && _isImage(displaySource);
        final hasViewable = isServer || isLocalFile;
        final label = !hasValue
            ? 'Select file'
            : (displaySource != null
                  ? _getFileName(displaySource)
                  : (isPendingUnresolved
                        ? 'Pending upload…'
                        : _getFileName(current)));
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: enabled && !field.readOnly
                        ? () async {
                            final messenger = ScaffoldMessenger.of(context);
                            // `sdkLog` is debug-only, so every failure below was
                            // invisible in release: the picker closed, the field
                            // stayed empty, and nothing explained why. Also
                            // guards `pickFiles` itself, which throws on a
                            // denied storage permission.
                            try {
                              // Normalised across the supported file_picker
                              // major range, and reduced to the single path
                              // this field holds — see [pickedPathOf]. Cancel,
                              // an unreadable shape and a pathless entry all
                              // arrive here as null.
                              final files = pickedFilesOf(
                                await FilePicker.pickFiles(),
                              );
                              final path = pickedPathOf(files);
                              if (path == null) return;
                              if (files.length > 1) {
                                // From file_picker 12 the dialog is multi-select
                                // and cannot be told otherwise — there is no
                                // single-select call common to the whole
                                // supported range (11.x has no `pickFile()`,
                                // 13.x has no `allowMultiple`). So a user can
                                // genuinely select several files for a field
                                // that holds one, and taking the first is
                                // forced rather than chosen. Say so: dropping
                                // the extras in silence is the same failure
                                // this replaced, only quieter.
                                _notify(
                                  messenger,
                                  'Only the first file was attached.',
                                );
                              }
                              final picked = File(path);
                              // Durable-copy-first; upload inline when online,
                              // else keep the local path for save-time queueing.
                              //
                              // This deliberately REPLACES the older "never
                              // store the local path — the server expects a
                              // file_url" rule. A local path is now a valid
                              // stored value: the offline attachment producer
                              // queues it at save time and rewrites the field
                              // once the upload lands. `resolvePickedAttachment`
                              // absorbs the null-uploader and failed-upload
                              // branches that used to be spelled out here, and
                              // falls back to the durable copy in both.
                              final stored = await resolvePickedAttachment(
                                picked: picked,
                                online: isOnline?.call() ?? true,
                                offlineModeEnabled:
                                    isOfflineMode?.call() ?? false,
                                uploadFile: uploadFile,
                              );
                              if (stored != null && stored.isNotEmpty) {
                                // Reclaim the file this pick replaces.
                                // Guarded by isStagedPath, so a host path or a
                                // pending: marker is untouched — and by the
                                // queue when the host wired a database-backed
                                // reclaim.
                                //
                                // `current`, NOT `fieldState.value`: before the
                                // first interaction the form-field value is
                                // still null while the widget value holds the
                                // attachment a document load supplied, so the
                                // raw value reclaimed nothing and the staged
                                // file this pick replaced was leaked until the
                                // orphan sweep found it. `current` is the same
                                // hasInteractedByUser-aware value the discard
                                // path already uses — the two paths disagreeing
                                // about which value is live is the bug.
                                await reclaimAttachment(current);
                                fieldState.didChange(stored);
                                onChanged?.call(stored);
                                return;
                              }
                              // Only reachable if the durable copy itself
                              // yielded nothing, so there is no local path to
                              // queue either — the pick is genuinely lost.
                              sdkLog(
                                'AttachField: could not store the picked file '
                                '${picked.path}',
                              );
                              _notify(
                                messenger,
                                'Upload failed — the file was not attached.',
                              );
                            } on AttachmentTooLargeException catch (e) {
                              // Refused before staging, so nothing to clean up.
                              // The message names the real limit: "too large"
                              // alone leaves the user guessing how much to trim.
                              _notify(messenger, attachmentTooLargeMessage(e));
                            } catch (e, st) {
                              sdkLog('AttachField: attach failed — $e\n$st');
                              _notify(
                                messenger,
                                isTerminalAttachmentError(e)
                                    // The server refused it outright; a retry
                                    // cannot help, so do not imply otherwise.
                                    ? 'The server rejected this file, so it was '
                                          'not attached.'
                                    : 'Could not attach the file. Check your '
                                          'connection and storage permissions.',
                              );
                            }
                          }
                        : null,
                    icon: const Icon(Icons.attach_file),
                    label: Text(label),
                  ),
                ),
                // View/Open affordance — available even when the field is
                // read-only/disabled so users can always view an attachment
                // (QA #11). Hidden for an unresolved pending pick (nothing to
                // open yet).
                // Discard. Shown only when there IS something to remove and
                // the field is editable. A mandatory field can still be
                // cleared — requiredValidator catches it at save, which is the
                // right place; blocking the clear would trap a user who wants
                // to replace via discard-then-pick.
                if (hasValue && enabled && !field.readOnly)
                  IconButton(
                    tooltip: 'Remove attachment',
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      // Clear FIRST. The user's action must take effect even if
                      // reclaiming the bytes fails — a leftover file is an
                      // orphan the sweep collects, whereas a failed reclaim
                      // aborting this callback would leave the attachment in
                      // place while the user believes it is gone.
                      final discarded = current;
                      fieldState.didChange(null);
                      onChanged?.call(null);
                      await reclaimAttachment(discarded);
                    },
                  ),
                if (hasViewable)
                  // Resolution moved INTO the button, so it happens on tap
                  // rather than while the form builds. A `MediaResolveBuilder`
                  // here started the fetch from `initState`, which meant
                  // opening a form downloaded every attachment on it before the
                  // user asked for any — and this widget only renders a button,
                  // so there was never a render-time need for the bytes.
                  //
                  // `url`/`isLocal` are the FALLBACK: what to use when the
                  // resolve misses (offline, unknown marker, failed fetch), so
                  // the button still opens over the network exactly as before.
                  //
                  // The RESOLVED path only ever replaces the view TARGET.
                  // Labels stay derived from `displaySource` (the value or the
                  // staged path) — routing them through the cache path would
                  // show sha256(file_url) instead of "report.pdf".
                  _AttachViewButton(
                    url: isServer
                        ? (_fullFileUrl(displaySource) ?? displaySource)
                        : displaySource,
                    isLocal: isLocalFile,
                    isImage: isImage,
                    headers: isServer
                        ? authHeadersForUrl(
                            _fullFileUrl(displaySource) ?? displaySource,
                            imageHeaders,
                            fileUrlBase,
                          )
                        : imageHeaders,
                    // `displaySource`, not `current`: a `pending:<id>` marker
                    // resolves to its durable local file, so the label shows
                    // the real filename not the marker text.
                    fileName: _getFileName(displaySource),
                    httpClient: httpClient,
                    resolveValue: current,
                    resolver: mediaResolver,
                    pendingPaths: pendingAttachmentPaths,
                  ),
              ],
            ),
            if (hasValue)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  isPendingUnresolved
                      ? 'Attached — pending upload'
                      : (displaySource ?? current),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            fieldErrorText(fieldState),
          ],
        );
      },
    );
  }

  String _getFileName(String path) {
    return path.split('/').last;
  }
}

/// View/Open button for an attachment. Kept stateful so it can show a loading
/// spinner while a non-image file is downloaded (with auth) before being opened
/// in the device's default app.
class _AttachViewButton extends StatefulWidget {
  /// Absolute, authenticated URL for server files, or the local device path.
  final String url;

  /// True when [url] is a local file already on the device (no download needed).
  final bool isLocal;

  /// True when the attachment is an image (opens in the full-screen viewer).
  final bool isImage;

  /// Auth headers used to fetch private server files.
  final Map<String, String>? headers;

  /// Display file name — used to recover the extension of the cached temp file.
  final String fileName;

  /// Caller-owned client for the download; null means "create and close one".
  final http.Client? httpClient;

  /// The stored field value to resolve through [resolver], or null to skip
  /// resolution and use [url] directly.
  final String? resolveValue;

  /// Cache-first resolver, consulted ON TAP rather than on mount.
  ///
  /// [AttachField] renders only a BUTTON — it never shows attachment content
  /// inline — so resolving while the form built meant every attachment on the
  /// form downloaded (up to the 25 MB resolver cap each) before the user asked
  /// for any of them. On a metered rural connection that is the difference
  /// between opening a form and opening a form plus five PDFs. [ImageField] is
  /// the opposite case and still resolves eagerly: its preview renders FROM the
  /// local file, so it genuinely needs the path to paint.
  final ResolveMediaFn? resolver;

  /// Marker map handed to [resolver] so a `pending:<id>` value resolves.
  final Map<int, String>? pendingPaths;

  const _AttachViewButton({
    required this.url,
    required this.isLocal,
    required this.isImage,
    required this.headers,
    required this.fileName,
    required this.httpClient,
    this.resolveValue,
    this.resolver,
    this.pendingPaths,
  });

  @override
  State<_AttachViewButton> createState() => _AttachViewButtonState();
}

class _AttachViewButtonState extends State<_AttachViewButton> {
  /// Hard ceiling on an attachment we will pull down for an external app.
  /// Bytes are streamed straight to disk so RAM is never the constraint, but a
  /// mis-sized (or hostile) file must not be able to fill the app's cache
  /// directory or silently burn a metered connection. 50 MB is far above a
  /// normal Frappe attachment — scans, photos and reports are single-digit MB —
  /// while staying small enough to remain a genuine guard rail.
  static const int maxDownloadBytes = 50 * 1024 * 1024;

  /// Budget for the server to start responding. Without it a hung server left
  /// the spinner spinning forever with no way out (there is no cancel button).
  static const Duration responseTimeout = Duration(seconds: 30);

  /// Longest idle gap tolerated between two chunks once bytes are flowing.
  /// Applied per chunk rather than to the whole transfer so a legitimately
  /// large file on a slow rural connection still completes.
  static const Duration stallTimeout = Duration(seconds: 30);

  bool _busy = false;

  /// Set in [dispose]. The download runs to completion regardless — there is no
  /// cancel token on `http.Client.send`'s stream that would abort it cleanly
  /// mid-write — but once unmounted we must not hand the file to an external
  /// app. Without this, tapping Open on a large PDF and then navigating away
  /// launched a viewer over whatever the user had moved on to.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    // Only close a client this widget owns; an injected one belongs to the
    // caller (see [_AttachViewButton.httpClient]).
    _ownedClient?.close();
    _ownedClient = null;
    super.dispose();
  }

  /// The client created by [_open] when none was injected, tracked so [dispose]
  /// can close it and abort an in-flight download's socket.
  http.Client? _ownedClient;

  Future<void> _open() async {
    // Cache-first resolution happens HERE, on tap — not in a builder that runs
    // when the field mounts. See [_AttachViewButton.resolver]: this widget only
    // ever renders a button, so an eager resolve downloaded attachments nobody
    // had asked to see. A resolved hit is by definition a local file, so it
    // takes the same branches below as a staged pick.
    var url = widget.url;
    var isLocal = widget.isLocal;
    final resolver = widget.resolver;
    final value = widget.resolveValue?.trim();
    if (resolver != null && value != null && value.isNotEmpty) {
      // The resolve itself can hit the network on a cache miss, so it gets the
      // spinner too — otherwise the first tap on an uncached attachment looked
      // like nothing had happened.
      setState(() => _busy = true);
      String? resolved;
      try {
        resolved = await resolver(value, pendingPaths: widget.pendingPaths);
      } catch (e, st) {
        // A failed resolve is a cache miss, not an error the user must see:
        // the fallbacks below still open the file over the network.
        sdkLog('AttachField: media resolve failed — $e\n$st');
      }
      if (_disposed) return;
      if (mounted) setState(() => _busy = false);
      if (resolved != null && resolved.isNotEmpty) {
        url = resolved;
        isLocal = true;
      }
    }

    // Images: reuse the shared full-screen zoomable viewer.
    if (widget.isImage) {
      if (!mounted) return;
      if (isLocal) {
        showFullScreenImageProvider(context, FileImage(File(url)));
      } else {
        showFullScreenImage(context, url, widget.headers);
      }
      return;
    }

    // Local non-image file — open directly, no download required.
    if (isLocal) {
      final result = await OpenFilex.open(url);
      if (result.type != ResultType.done && mounted) {
        _showError('Could not open file: ${result.message}');
      }
      return;
    }

    // Remote non-image (PDF/doc/etc.): private Frappe files need auth headers an
    // external app/browser won't have, so fetch the bytes ourselves then open
    // the downloaded temp file.
    setState(() => _busy = true);
    // Reuse an injected client; otherwise create one and close it below.
    final client = widget.httpClient ?? http.Client();
    if (widget.httpClient == null) _ownedClient = client;
    File? target;
    try {
      final request = http.Request('GET', Uri.parse(url));
      final headers = widget.headers;
      if (headers != null) request.headers.addAll(headers);
      // Streamed (not http.get) so the whole file is never buffered in memory:
      // a large PDF/video used to be materialised as response.bodyBytes.
      final response = await client.send(request).timeout(responseTimeout);
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final declared = response.contentLength;
      // A missing content-length (chunked responses, which the Frappe
      // download_file proxy can produce) just means "unknown" — the running
      // byte count below is the load-bearing guard.
      if (declared != null && declared > maxDownloadBytes) {
        throw const _AttachmentTooLarge();
      }
      // Through MediaStore, NOT a second `getTemporaryDirectory()` +
      // `attachmentTempDirName` of our own. The two constructions produced the
      // same string, so nothing was broken — but only by coincidence, and this
      // directory is the one `MediaStore.clearAll` wipes on logout and
      // `usage` measures. Two independent spellings of a path where one side
      // deletes what the other writes is the divergence that already caused the
      // `moveToCache` / `resolve` cache-path bug in this same release. One
      // source of truth also means the test override reaches this writer.
      target = File(
        p.join(
          await MediaStore.viewerTempDir(),
          attachmentTempFileName(url, widget.fileName),
        ),
      );
      await target.parent.create(recursive: true);
      final sink = target.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(stallTimeout)) {
          received += chunk.length;
          if (received > maxDownloadBytes) throw const _AttachmentTooLarge();
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      // The user may have navigated away while this downloaded. Launching an
      // external viewer now would appear over an unrelated screen, so drop the
      // file instead. Checked AFTER the write completes because the stream
      // cannot be aborted mid-chunk.
      if (_disposed) {
        await _deleteQuietly(target);
        return;
      }
      final result = await OpenFilex.open(target.path);
      if (result.type != ResultType.done && mounted) {
        _showError('Could not open file: ${result.message}');
      }
    } on TimeoutException {
      await _deleteQuietly(target);
      if (mounted) {
        _showError('Download timed out. Check your connection and try again.');
      }
    } on _AttachmentTooLarge {
      await _deleteQuietly(target);
      if (mounted) {
        _showError(
          'File is too large to open on this device '
          '(limit ${maxDownloadBytes ~/ (1024 * 1024)} MB).',
        );
      }
    } catch (e) {
      await _deleteQuietly(target);
      if (mounted) _showError('Could not open file: $e');
    } finally {
      if (widget.httpClient == null) client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Removes a partially written cache file so a later attempt (or a later tap)
  /// can never hand truncated bytes to an external app.
  Future<void> _deleteQuietly(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      sdkLog('AttachField: could not delete partial download — $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(12.0),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return IconButton(
      icon: Icon(widget.isImage ? Icons.visibility : Icons.open_in_new),
      tooltip: widget.isImage ? 'View' : 'Open',
      onPressed: _open,
    );
  }
}
