// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'base_field.dart';

/// Widget for Image/Attach Image field type
class ImageField extends BaseField {
  const ImageField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (field.label != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: Text(
                  field.label!,
                  style: style?.labelStyle,
                ),
              ),
            if (imagePath != null && imagePath.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(imagePath),
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
                          final result = await picker.pickImage(source: ImageSource.gallery);
                          if (result != null) {
                            fieldState.didChange(result.path);
                            onChanged?.call(result.path);
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
                          final result = await picker.pickImage(source: ImageSource.camera);
                          if (result != null) {
                            fieldState.didChange(result.path);
                            onChanged?.call(result.path);
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
