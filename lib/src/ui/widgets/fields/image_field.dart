// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:image_picker/image_picker.dart';
import 'base_field.dart';

/// Widget for Image/Attach Image field type.
/// When [uploadFile] is set, picks upload to server first and store file_url; otherwise stores local path.
class ImageField extends BaseField {
  final Future<String?> Function(File file)? uploadFile;
  final String? fileUrlBase;

  const ImageField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.uploadFile,
    this.fileUrlBase,
  });

  /// Only Frappe server file paths or full URLs; local paths like /home/..., /Users/... are not server URLs.
  bool _isServerUrl(String? path) {
    if (path == null || path.isEmpty) return false;
    if (path.startsWith('http://') || path.startsWith('https://')) return true;
    // Frappe file_url is typically /files/...; avoid treating local paths as server
    if (path.startsWith('/files/')) return true;
    if (path.startsWith('/home/') ||
        path.startsWith('/Users/') ||
        path.startsWith('/tmp/')) {
      return false;
    }
    if (path.contains('/Pictures/') || path.contains('/Screenshots/')) {
      return false;
    }
    // Other leading / could be server path
    return path.startsWith('/');
  }

  String? _fullImageUrl(String? path) {
    if (path == null || path.isEmpty || fileUrlBase == null) return path;
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    if (!_isServerUrl(path)) return path;
    final base = fileUrlBase!.endsWith('/') ? fileUrlBase! : '${fileUrlBase!}/';
    return path.startsWith('/') ? '$base${path.substring(1)}' : '$base$path';
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
    String? imagePath = value?.toString();

    return FormBuilderField<String>(
      key: ValueKey('${field.fieldname}_$imagePath'),
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
        final currentValue = fieldState.value ?? imagePath;
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
                  child: isUrl && displayUrl != null
                      ? Image.network(
                          displayUrl,
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
                      : Image.file(
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
