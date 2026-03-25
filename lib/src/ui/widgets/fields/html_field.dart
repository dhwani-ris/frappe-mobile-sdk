import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html/flutter_widget_from_html.dart';
import 'base_field.dart';

/// Renders a Frappe HTML field using an HTML renderer.
/// HTML fields are display-only — they have no editable value.
class HtmlField extends BaseField {
  const HtmlField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget build(BuildContext context) {
    if (field.hidden) return const SizedBox.shrink();
    // HTML fields store their content in field.options (the DocField meta),
    // not as a document value.
    final html = field.options?.trim() ?? (value as String?)?.trim() ?? '';
    if (html.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: HtmlWidget(html),
    );
  }

  @override
  Widget buildField(BuildContext context) => const SizedBox.shrink();
}
