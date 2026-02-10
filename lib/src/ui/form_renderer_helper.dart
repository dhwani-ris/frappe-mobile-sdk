// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import '../sdk/frappe_sdk.dart';
import 'widgets/form_builder.dart' show FrappeFormBuilder, FrappeFormStyle;
import 'widgets/default_form_style.dart';
import 'form_screen.dart';

/// Helper class for easy form rendering
class FrappeFormRenderer {
  final FrappeSDK sdk;
  final FrappeFormStyle? style;

  FrappeFormRenderer({required this.sdk, this.style});

  /// Render a form widget for a doctype
  ///
  /// Example:
  /// ```dart
  /// final renderer = FrappeFormRenderer(sdk: sdk);
  /// final form = await renderer.renderForm('Customer');
  /// ```
  Future<Widget> renderForm(
    String doctype, {
    Map<String, dynamic>? initialData,
    Function(Map<String, dynamic>)? onSubmit,
    bool readOnly = false,
  }) async {
    final meta = await sdk.meta.getMeta(doctype);

    return FrappeFormBuilder(
      meta: meta,
      initialData: initialData,
      onSubmit: onSubmit,
      readOnly: readOnly,
      linkOptionService: sdk.linkOptions,
      style: style ?? DefaultFormStyle.standard,
    );
  }

  /// Navigate to a form screen
  ///
  /// Example:
  /// ```dart
  /// await renderer.navigateToForm(context, 'Customer');
  /// ```
  Future<void> navigateToForm(
    BuildContext context,
    String doctype, {
    Map<String, dynamic>? initialData,
    Function()? onSaveSuccess,
  }) async {
    final meta = await sdk.meta.getMeta(doctype);

    final document = initialData != null && initialData['name'] != null
        ? await sdk.repository.getDocumentByServerId(
            initialData['name'],
            doctype,
          )
        : null;

    if (!context.mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => FormScreen(
          meta: meta,
          document: document,
          repository: sdk.repository,
          syncService: sdk.sync,
          linkOptionService: sdk.linkOptions,
          api: sdk.api,
          onSaveSuccess: onSaveSuccess,
          getMobileUuid: () => sdk.getMobileUuid(),
        ),
      ),
    );
  }
}
