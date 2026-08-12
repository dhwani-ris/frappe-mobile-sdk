// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../../models/doc_field.dart';
import '../../../utils/sdk_log.dart';
import 'base_field.dart';
import 'field_helpers.dart';

/// Shows [image] full-screen in a zoomable, dismissible viewer with a dark
/// scrim and a close (X) button. Pinch-zoom / pan via [InteractiveViewer];
/// never crops (BoxFit.contain). Shared by ImageField (thumbnail tap) and
/// AttachField (image attachments).
void showFullScreenImageProvider(BuildContext context, ImageProvider image) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (dialogContext) {
      return Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4.0,
                child: Image(
                  image: image,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: Icon(
                        Icons.broken_image,
                        color: Colors.white70,
                        size: 64,
                      ),
                    );
                  },
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  },
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 16,
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Shows a network image full-screen with optional auth [headers]. Shared entry
/// point used by ImageField and AttachField so private Frappe files load with
/// the same auth as inline previews.
void showFullScreenImage(
  BuildContext context,
  String url,
  Map<String, String>? headers,
) {
  showFullScreenImageProvider(context, NetworkImage(url, headers: headers));
}

/// Name of the marker file written to the app's cache dir immediately before a
/// camera capture is launched. It survives the host activity (and process) being
/// killed mid-capture, which is the only way a later run can tell WHICH field
/// the platform's stashed photo belongs to.
const String _captureMarkerFileName = 'frappe_sdk_camera_capture.marker';

/// A marker older than this is treated as abandoned. Without an age bound, a
/// field whose capture was interrupted days ago would resurface that ancient
/// photo the next time its camera button is tapped.
const Duration _captureMarkerMaxAge = Duration(minutes: 30);

/// Identity written into the capture marker so a recovered photo can be scoped
/// back to the field that actually took it. [ImagePicker.retrieveLostData]'s
/// cache is app-wide, so this key is the only thing standing between field A's
/// photo and field B's tap.
///
/// LIMITATION: [DocField] carries no owning-doctype/row identifier, so the key
/// is the fieldtype + fieldname alone. Two ImageFields that share a fieldname —
/// the same fieldname in two different forms, or in two child-table rows — can
/// still cross-claim a recovered photo. Narrowing that further needs an owner
/// identifier the field model does not currently expose.
@visibleForTesting
String cameraCaptureMarkerKey(DocField field) =>
    '${field.fieldtype}/${field.fieldname ?? ''}';

/// Widget for Image/Attach Image field type.
/// When [uploadFile] is set, picks upload to server first and store file_url; otherwise stores local path.
/// For /private/files/ and /files/, uses Frappe download_file API and [imageHeaders] for auth.
class ImageField extends BaseField {
  final Future<String?> Function(File file)? uploadFile;
  final String? fileUrlBase;

  /// Auth headers (e.g. from [FrappeClient.requestHeaders]) so private file URLs load.
  final Map<String, String>? imageHeaders;

  const ImageField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.uploadFile,
    this.fileUrlBase,
    this.imageHeaders,
  });

  /// Only Frappe server file paths or full URLs are treated as server URLs.
  /// Local absolute paths (/storage/..., /data/..., /home/..., etc.) are NOT server URLs.
  bool _isServerUrl(String? path) {
    if (path == null || path.isEmpty) return false;
    final p = path.trim();
    if (p.startsWith('http://') || p.startsWith('https://')) return true;
    if (p.startsWith('/files/') || p.startsWith('/private/files/')) return true;
    // multi_cloud_storage (and any Frappe method-served file) returns a
    // RELATIVE proxy URL, e.g.
    //   /api/method/multi_cloud_storage.controller.generate_file?key=...
    // Without this, such values fail the check below, get mistaken for a local
    // path, and render via Image.file (broken). Treat method endpoints as
    // server URLs so _fullImageUrl prepends the base and the preview loads via
    // Image.network(base + path) with auth headers. (Cloud-backed private files.)
    if (p.startsWith('/api/method/')) return true;
    return false;
  }

  /// True if url is absolute (http/https), so Image.network can use it.
  bool _isFullUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final u = url.trim();
    return u.startsWith('http://') || u.startsWith('https://');
  }

  /// Build display URL: full URLs (S3, http(s)) use as-is.
  /// /private/files/ and /files/ use download_file API so auth works; other / paths get base prepended.
  String? _fullImageUrl(String? path) {
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

  /// Surfaces [message] to the user. `sdkLog` is `kDebugMode`-only, so without
  /// this a release-build failure was completely invisible: the user took a
  /// photo, the upload failed, the field stayed empty, and nothing said why.
  ///
  /// Takes a [ScaffoldMessengerState] rather than a [BuildContext] on purpose:
  /// every caller is past an `await`, and resolving the messenger from a context
  /// after an async gap is exactly what `use_build_context_synchronously` warns
  /// about. Callers capture it before their first await instead.
  static void _notify(ScaffoldMessengerState messenger, String message) {
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Applies a picked/recovered [file] to the field. Returns true only when the
  /// field value actually changed, so callers never report success over a field
  /// that an upload failure left empty.
  ///
  /// [messenger], when supplied, receives a SnackBar on failure. Optional so
  /// the recovery path — which shows its own message — can opt out.
  Future<bool> _onImagePicked(
    FormFieldState<String> fieldState,
    File file, {
    ScaffoldMessengerState? messenger,
  }) async {
    if (uploadFile != null) {
      try {
        final url = await uploadFile!(file);
        if (url != null && url.isNotEmpty) {
          fieldState.didChange(url);
          onChanged?.call(url);
          return true;
        }
        // Upload "succeeded" but returned nothing usable. Previously this path
        // returned false with NO log at all — silent even in debug.
        sdkLog('ImageField: uploadFile returned an empty URL for ${file.path}');
        if (messenger != null) {
          _notify(messenger, 'Upload failed — the photo was not attached.');
        }
      } catch (e, st) {
        // Do not fall back to local path; leave field unchanged so wrong URL is never sent
        sdkLog('ImageField: uploadFile failed — $e\n$st');
        if (messenger != null) {
          _notify(
            messenger,
            'Could not upload the photo. Check your connection and try again.',
          );
        }
      }
      return false;
    }
    fieldState.didChange(file.path);
    onChanged?.call(file.path);
    return true;
  }

  /// Handle to the capture marker, or null when the cache dir is unavailable
  /// (path_provider missing, e.g. in a widget test).
  Future<File?> _captureMarkerFile() async {
    try {
      final dir = await getTemporaryDirectory();
      return File('${dir.path}/$_captureMarkerFileName');
    } catch (e) {
      sdkLog('ImageField: cache dir unavailable for capture marker — $e');
      return null;
    }
  }

  /// Claims the lost-data slot for this field just before the camera is
  /// launched. Best-effort: if the marker cannot be written the only cost is
  /// that an interrupted capture will not be recovered (the pre-marker
  /// behaviour of dropping it), never a photo landing on the wrong field.
  Future<void> _writeCaptureMarker() async {
    if (!Platform.isAndroid) return;
    try {
      final marker = await _captureMarkerFile();
      await marker?.writeAsString(cameraCaptureMarkerKey(field), flush: true);
    } catch (e) {
      sdkLog('ImageField: could not write capture marker — $e');
    }
  }

  Future<void> _clearCaptureMarker() async {
    if (!Platform.isAndroid) return;
    try {
      final marker = await _captureMarkerFile();
      if (marker != null && await marker.exists()) await marker.delete();
    } catch (e) {
      sdkLog('ImageField: could not clear capture marker — $e');
    }
  }

  /// Consumes a photo the platform stashed when Android killed the host activity
  /// mid-capture — but ONLY when the marker written before that interrupted
  /// capture names THIS field, and only while it is recent.
  ///
  /// Returns true when a photo was restored, in which case the caller must not
  /// start a new capture. The user is told why their tap did not open the
  /// camera; previously the tap was silently swallowed and an older photo
  /// appeared instead.
  ///
  /// Deliberately does NOT call [ImagePicker.retrieveLostData] when the marker
  /// belongs to another field: that call CLEARS the platform cache, so probing
  /// it here would destroy the photo the owning field is still entitled to
  /// recover.
  Future<bool> _restoreInterruptedCapture(
    BuildContext context,
    ImagePicker picker,
    FormFieldState<String> fieldState,
  ) async {
    if (!Platform.isAndroid) return false;
    final marker = await _captureMarkerFile();
    if (marker == null) return false;
    final String owner;
    final DateTime writtenAt;
    try {
      if (!await marker.exists()) return false;
      owner = (await marker.readAsString()).trim();
      writtenAt = await marker.lastModified();
    } catch (e) {
      sdkLog('ImageField: could not read capture marker — $e');
      return false;
    }
    final stale = DateTime.now().difference(writtenAt) > _captureMarkerMaxAge;
    if (stale || owner != cameraCaptureMarkerKey(field)) {
      // Drop an abandoned marker, but leave another field's marker (and the
      // platform's stashed photo) alone.
      if (stale) await _clearCaptureMarker();
      return false;
    }
    await _clearCaptureMarker();
    try {
      final lost = await picker.retrieveLostData();
      final lostFile = lost.file;
      if (lost.isEmpty || lostFile == null) return false;
      // An upload failure leaves the field empty — do not claim a restore (and
      // do not swallow the tap) in that case.
      if (!await _onImagePicked(fieldState, File(lostFile.path))) return false;
    } catch (e) {
      // Recovery is best-effort (iOS throws UnimplementedError) — the caller
      // falls through to a normal capture.
      sdkLog('ImageField: lost-capture recovery failed — $e');
      return false;
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Restored the photo taken before the app restarted. '
            'Tap the camera again to replace it.',
          ),
        ),
      );
    }
    return true;
  }

  @override
  Widget buildField(BuildContext context) {
    final raw = value?.toString();
    final String? imagePath = raw?.trim();

    return FormBuilderField<String>(
      autovalidateMode: AutovalidateMode.onUserInteraction,
      key: ValueKey('image_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: imagePath,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) => requiredValidator(value, field.displayLabel)
          : null,
      builder: (FormFieldState<String> fieldState) {
        final raw = fieldState.value ?? imagePath;
        final currentValue = raw?.toString().trim();
        final isUrl = _isServerUrl(currentValue);
        final displayUrl = isUrl ? _fullImageUrl(currentValue) : null;

        // BaseField.build (the enclosing widget) already renders the
        // external label with required-asterisk; the inline label that
        // used to live here is gone for parity with text/numeric/etc.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (currentValue != null && currentValue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: GestureDetector(
                  // Viewing is always allowed — even when the field is
                  // read-only/disabled the user can still open the full-screen
                  // viewer (QA #11).
                  onTap: () {
                    if (_isFullUrl(displayUrl)) {
                      showFullScreenImage(context, displayUrl!, imageHeaders);
                    } else if (!isUrl) {
                      showFullScreenImageProvider(
                        context,
                        FileImage(File(currentValue)),
                      );
                    }
                  },
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: _isFullUrl(displayUrl)
                            ? Image.network(
                                displayUrl!,
                                height: 150,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                headers: imageHeaders,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    height: 150,
                                    color: Colors.grey[300],
                                    child: const Icon(Icons.broken_image),
                                  );
                                },
                              )
                            : !isUrl
                            ? Image.file(
                                File(currentValue),
                                height: 150,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) {
                                  return Container(
                                    height: 150,
                                    color: Colors.grey[300],
                                    child: const Icon(Icons.broken_image),
                                  );
                                },
                              )
                            : Container(
                                height: 150,
                                color: Colors.grey[300],
                                child: const Center(
                                  child: Icon(Icons.broken_image, size: 48),
                                ),
                              ),
                      ),
                      // 'Tap to view' affordance — only shown when the image is
                      // actually viewable full-screen.
                      if (_isFullUrl(displayUrl) || !isUrl)
                        Positioned(
                          right: 8,
                          bottom: 8,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(
                              Icons.fullscreen,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: enabled && !field.readOnly
                      ? () async {
                          // pickImage throws on a denied gallery permission —
                          // a routine case, not an edge one. Unguarded it became
                          // an unhandled async error from onPressed with nothing
                          // shown to the user.
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            final picker = ImagePicker();
                            final result = await picker.pickImage(
                              source: ImageSource.gallery,
                            );
                            if (result != null) {
                              await _onImagePicked(
                                fieldState,
                                File(result.path),
                                messenger: messenger,
                              );
                            }
                          } catch (e, st) {
                            sdkLog('ImageField: gallery pick failed — $e\n$st');
                            _notify(
                              messenger,
                              'Could not open the gallery. Check photo '
                              'permissions in Settings.',
                            );
                          }
                        }
                      : null,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('Gallery'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: enabled && !field.readOnly
                      ? () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final picker = ImagePicker();
                          // Android can kill the host activity mid-capture
                          // and stash the result; without recovering it the
                          // FIRST capture is silently dropped and users must
                          // shoot twice ("camera-twice" bug). The stash is
                          // app-wide, so only the field named by the marker
                          // written before that capture may claim it —
                          // otherwise field B's tap could pick up field A's
                          // photo.
                          if (await _restoreInterruptedCapture(
                            context,
                            picker,
                            fieldState,
                          )) {
                            return;
                          }
                          await _writeCaptureMarker();
                          try {
                            final result = await picker.pickImage(
                              source: ImageSource.camera,
                            );
                            if (result != null) {
                              // A photo came back inside this run, so nothing is
                              // stashed — the marker has done its job.
                              await _clearCaptureMarker();
                              await _onImagePicked(
                                fieldState,
                                File(result.path),
                                messenger: messenger,
                              );
                            }
                            // A null result is ambiguous: the user cancelled, OR
                            // Android recreated the activity and stashed the
                            // photo (pickImage then completes with null). The
                            // marker is deliberately LEFT in place — clearing it
                            // here would make that stashed photo unrecoverable,
                            // which is the very bug this marker exists to fix.
                            // A plain cancel costs one empty retrieveLostData()
                            // on the next tap, and the age bound expires it.
                          } catch (e, st) {
                            await _clearCaptureMarker();
                            // Previously rethrown from inside onPressed — an
                            // unhandled async error with no user-visible
                            // message. A denied camera permission is the common
                            // trigger, so report it instead of crashing the
                            // zone.
                            sdkLog(
                              'ImageField: camera capture failed — $e\n$st',
                            );
                            _notify(
                              messenger,
                              'Could not open the camera. Check camera '
                              'permissions in Settings.',
                            );
                          }
                        }
                      : null,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ],
            ),
            fieldErrorText(fieldState),
          ],
        );
      },
    );
  }
}
