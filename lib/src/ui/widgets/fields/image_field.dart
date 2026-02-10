// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:image_picker/image_picker.dart';
import 'base_field.dart';

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

  Future<void> _onImagePicked(
    FormFieldState<String> fieldState,
    File file,
  ) async {
    if (uploadFile != null) {
      try {
        final url = await uploadFile!(file);
        if (url != null && url.isNotEmpty) {
          fieldState.didChange(url);
          onChanged?.call(url);
        }
        // On upload failure or empty response, do not store local path (server expects file_url)
      } catch (_) {
        // Do not fall back to local path; leave field unchanged so wrong URL is never sent
      }
    } else {
      fieldState.didChange(file.path);
      onChanged?.call(file.path);
    }
  }

  @override
  Widget buildField(BuildContext context) {
    final raw = value?.toString();
    final String? imagePath = raw?.trim();

    return FormBuilderField<String>(
      key: ValueKey('image_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: imagePath,
      enabled: enabled && !field.readOnly,
      validator: field.reqd
          ? (value) {
              if (value == null || value.isEmpty) {
                return '${field.displayLabel} is required';
              }
              return null;
            }
          : null,
      builder: (FormFieldState<String> fieldState) {
        final raw = fieldState.value ?? imagePath;
        final currentValue = raw?.toString().trim();
        final isUrl = _isServerUrl(currentValue);
        final displayUrl = isUrl ? _fullImageUrl(currentValue) : null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (field.label != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(field.label!, style: style?.labelStyle),
              ),
            if (currentValue != null && currentValue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: ClipRRect(
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
              ),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: enabled && !field.readOnly
                      ? () async {
                          final picker = ImagePicker();
                          final result = await picker.pickImage(
                            source: ImageSource.gallery,
                          );
                          if (result != null) {
                            await _onImagePicked(fieldState, File(result.path));
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
                          final picker = ImagePicker();
                          final result = await picker.pickImage(
                            source: ImageSource.camera,
                          );
                          if (result != null) {
                            await _onImagePicked(fieldState, File(result.path));
                          }
                        }
                      : null,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Camera'),
                ),
              ],
            ),
            if (fieldState.hasError)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  fieldState.errorText!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
          ],
        );
      },
    );
  }
}
