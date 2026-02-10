// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'base_field.dart';

/// Widget for Attach field type.
/// When [uploadFile] is set, picks upload to server first and store file_url; otherwise stores local path.
class AttachField extends BaseField {
  final Future<String?> Function(File file)? uploadFile;

  const AttachField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.uploadFile,
  });

  @override
  Widget buildField(BuildContext context) {
    String? filePath = value?.toString();

    return FormBuilderField<String>(
      key: ValueKey('attach_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: filePath,
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (field.label != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(field.label!, style: style?.labelStyle),
              ),
            OutlinedButton.icon(
              onPressed: enabled && !field.readOnly
                  ? () async {
                      final result = await FilePicker.platform.pickFiles();
                      if (result != null && result.files.single.path != null) {
                        final path = result.files.single.path!;
                        final file = File(path);
                        if (uploadFile != null) {
                          try {
                            final url = await uploadFile!(file);
                            if (url != null && url.isNotEmpty) {
                              fieldState.didChange(url);
                              onChanged?.call(url);
                            }
                            // On failure do not store local path (server expects file_url)
                          } catch (_) {}
                        } else {
                          fieldState.didChange(path);
                          onChanged?.call(path);
                        }
                      }
                    }
                  : null,
              icon: const Icon(Icons.attach_file),
              label: Text(
                filePath != null ? _getFileName(filePath) : 'Select file',
              ),
            ),
            if (filePath != null && filePath.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  filePath,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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

  String _getFileName(String path) {
    return path.split('/').last;
  }
}
