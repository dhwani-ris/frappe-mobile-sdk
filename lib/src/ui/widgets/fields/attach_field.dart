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
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import '../../../utils/sdk_log.dart';
import 'base_field.dart';
import 'field_helpers.dart';
// Reuse the shared full-screen zoomable image viewer (showFullScreenImage /
// showFullScreenImageProvider) so image attachments open exactly like
// ImageField previews, with the same auth headers.
import 'image_field.dart';

/// Dedicated subdirectory (under the OS temp dir) holding attachments that were
/// downloaded so an external app could open them. Keeping them in one folder
/// instead of loose in the temp root makes the cache identifiable and lets the
/// OS reclaim it as a unit.
@visibleForTesting
const String attachmentTempDirName = 'frappe_attachments';

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

  /// HTTP client used to download a non-image attachment before handing it to
  /// the device's default app. Optional: when null a short-lived client is
  /// created per download and closed afterwards (the pre-existing behaviour).
  /// A client passed in here is owned by the caller and is never closed by this
  /// widget. Exists so the download path can be exercised in tests.
  final http.Client? httpClient;

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
    this.httpClient,
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

  /// Build display URL: full URLs (S3, http(s)) use as-is.
  /// /private/files/ and /files/ use download_file API so auth works; other /
  /// paths get base prepended. Mirrors ImageField._fullImageUrl.
  String? _fullFileUrl(String? path) {
    if (path == null || path.isEmpty) return path;
    final p = path.trim();
    if (p.isEmpty) return path;
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    if (!p.startsWith('/') ||
        fileUrlBase == null ||
        fileUrlBase!.trim().isEmpty) {
      return p;
    }
    final base = fileUrlBase!.trim();
    final baseNoSlash = base.endsWith('/')
        ? base.substring(0, base.length - 1)
        : base;
    if (p.startsWith('/private/files/') || p.startsWith('/files/')) {
      return '$baseNoSlash/api/method/frappe.handler.download_file?file_url=${Uri.encodeComponent(p)}';
    }
    return '$baseNoSlash$p';
  }

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
        final current = (fieldState.value ?? filePath)?.trim();
        final hasValue = current != null && current.isNotEmpty;
        final isServer = hasValue && _isServerUrl(current);
        final isImage = hasValue && _isImage(current);
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
                              final result = await FilePicker.pickFiles();
                              if (result == null ||
                                  result.files.single.path == null) {
                                return;
                              }
                              final path = result.files.single.path!;
                              final file = File(path);
                              if (uploadFile == null) {
                                fieldState.didChange(path);
                                onChanged?.call(path);
                                return;
                              }
                              final url = await uploadFile!(file);
                              if (url != null && url.isNotEmpty) {
                                fieldState.didChange(url);
                                onChanged?.call(url);
                                return;
                              }
                              // Upload "succeeded" but returned nothing usable.
                              // Never store the local path — the server expects
                              // a file_url.
                              sdkLog(
                                'AttachField: uploadFile returned an empty URL '
                                'for $path',
                              );
                              _notify(
                                messenger,
                                'Upload failed — the file was not attached.',
                              );
                            } catch (e, st) {
                              sdkLog('AttachField: attach failed — $e\n$st');
                              _notify(
                                messenger,
                                'Could not attach the file. Check your '
                                'connection and storage permissions.',
                              );
                            }
                          }
                        : null,
                    icon: const Icon(Icons.attach_file),
                    label: Text(
                      hasValue ? _getFileName(current) : 'Select file',
                    ),
                  ),
                ),
                // View/Open affordance — available even when the field is
                // read-only/disabled so users can always view an attachment
                // (QA #11).
                if (hasValue)
                  _AttachViewButton(
                    // Images open in the shared full-screen viewer; other files
                    // are downloaded then opened externally.
                    url: isServer
                        ? (_fullFileUrl(current) ?? current)
                        : current,
                    isLocal: !isServer,
                    isImage: isImage,
                    headers: imageHeaders,
                    fileName: _getFileName(current),
                    httpClient: httpClient,
                  ),
              ],
            ),
            if (hasValue)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  current,
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

  const _AttachViewButton({
    required this.url,
    required this.isLocal,
    required this.isImage,
    required this.headers,
    required this.fileName,
    required this.httpClient,
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
    // Images: reuse the shared full-screen zoomable viewer.
    if (widget.isImage) {
      if (widget.isLocal) {
        showFullScreenImageProvider(context, FileImage(File(widget.url)));
      } else {
        showFullScreenImage(context, widget.url, widget.headers);
      }
      return;
    }

    // Local non-image file — open directly, no download required.
    if (widget.isLocal) {
      final result = await OpenFilex.open(widget.url);
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
      final request = http.Request('GET', Uri.parse(widget.url));
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
      final dir = await getTemporaryDirectory();
      target = File(
        '${dir.path}/$attachmentTempDirName/'
        '${attachmentTempFileName(widget.url, widget.fileName)}',
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
