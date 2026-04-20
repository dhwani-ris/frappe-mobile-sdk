// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import 'form_builder.dart' show FrappeFormStyle;

/// Default form styling configuration
class DefaultFormStyle {
  static FrappeFormStyle get standard => FrappeFormStyle(
    showFieldLabel: false,
    showFieldDescription: false,
    labelStyle: const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: Colors.black87,
    ),
    descriptionStyle: TextStyle(fontSize: 12, color: Colors.grey[600]),
    sectionTitleStyle: const TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.bold,
      color: Colors.black87,
    ),
    sectionMargin: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
    sectionPadding: const EdgeInsets.all(16),
    fieldPadding: const EdgeInsets.only(bottom: 16),
    showFieldLabel: true,
    fieldDecoration: (field) => InputDecoration(
      labelText: '${field.label ?? field.fieldname}${field.reqd ? ' *' : ''}',
      hintText: field.placeholder,
      helperText: field.description,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.grey[300]!),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.blue, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Colors.red),
      ),
      filled: true,
      fillColor: Colors.grey[50],
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
  );

  static FrappeFormStyle get compact => FrappeFormStyle(
    labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    sectionTitleStyle: const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
    ),
    sectionMargin: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
    sectionPadding: const EdgeInsets.all(12),
    fieldPadding: const EdgeInsets.only(bottom: 12),
    showFieldLabel: false,
    fieldDecoration: (field) => InputDecoration(
      hintText: field.placeholder ?? field.label ?? field.fieldname,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
  );

  static FrappeFormStyle get material => FrappeFormStyle(
    labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
    sectionTitleStyle: const TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.bold,
    ),
    sectionMargin: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
    sectionPadding: const EdgeInsets.all(20),
    fieldPadding: const EdgeInsets.only(bottom: 20),
    showFieldLabel: false,
    fieldDecoration: (field) => InputDecoration(
      hintText: field.placeholder ?? field.label ?? field.fieldname,
      border: const UnderlineInputBorder(),
      enabledBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: Colors.grey),
      ),
      focusedBorder: const UnderlineInputBorder(
        borderSide: BorderSide(color: Colors.blue, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 12),
    ),
  );
}
