import 'package:flutter/material.dart';
import '../../../models/doc_field.dart';
import '../../../models/doc_type_meta.dart';
import '../../../services/link_option_service.dart';
import '../../../database/entities/link_option_entity.dart';
import 'base_field.dart';
import 'searchable_select.dart';

/// Frappe "Table MultiSelect" field — renders via [SearchableSelect] in
/// multi-select mode. Resolves the child doctype's Link field automatically,
/// then delegates all search/chip UI to the shared widget.
class TableMultiSelectFieldBase extends BaseField {
  final List<dynamic> rows;
  final Future<DocTypeMeta> Function(String doctype) getMeta;
  final LinkOptionService? linkOptionService;

  const TableMultiSelectFieldBase({
    super.key,
    required super.field,
    required this.rows,
    required super.onChanged,
    required super.enabled,
    required this.getMeta,
    this.linkOptionService,
    super.style,
  }) : super(value: rows);

  @override
  Widget buildField(BuildContext context) {
    return _Loader(
      field: field,
      rows: rows,
      onChanged: onChanged,
      enabled: enabled && !field.readOnly,
      getMeta: getMeta,
      linkOptionService: linkOptionService,
    );
  }
}

/// Loads child-doctype meta + options, then shows [SearchableSelect].
class _Loader extends StatefulWidget {
  const _Loader({
    required this.field,
    required this.rows,
    required this.onChanged,
    required this.enabled,
    required this.getMeta,
    this.linkOptionService,
  });

  final DocField field;
  final List<dynamic> rows;
  final ValueChanged<dynamic>? onChanged;
  final bool enabled;
  final Future<DocTypeMeta> Function(String doctype) getMeta;
  final LinkOptionService? linkOptionService;

  @override
  State<_Loader> createState() => _LoaderState();
}

class _LoaderState extends State<_Loader> {
  List<LinkOptionEntity> _options = [];
  bool _loading = true;
  String? _linkFieldName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final childDoctype = widget.field.options;
      if (childDoctype == null || childDoctype.isEmpty) return;
      final childMeta = await widget.getMeta(childDoctype);
      for (final f in childMeta.fields) {
        if (f.fieldtype == 'Link' && f.options != null) {
          _linkFieldName = f.fieldname;
          if (widget.linkOptionService != null) {
            _options = await widget.linkOptionService!.getLinkOptions(
              f.options!,
            );
          }
          break;
        }
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _loading = false);
      // Emit a clean list value into _formData immediately after load.
      // This overwrites any corrupted string that document.data may
      // have carried into _formData (e.g. Dart toString() artifacts).
      _emitCleanValue();
    }
  }

  /// Push the current parsed selection back through onChanged so the
  /// form builder's _formData always holds a List<Map>, never a String.
  void _emitCleanValue() {
    if (_linkFieldName == null || widget.onChanged == null) return;
    final rows = _selected
        .map((v) => <String, dynamic>{_linkFieldName!: v})
        .toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChanged!(rows);
    });
  }

  List<String> get _selected {
    if (_linkFieldName == null) return [];
    return widget.rows
        .whereType<Map<String, dynamic>>()
        .map((r) => r[_linkFieldName]?.toString() ?? '')
        .where((v) => v.isNotEmpty)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return SearchableSelect(
      options: _options,
      selected: _selected,
      multiSelect: true,
      enabled: widget.enabled,
      loading: _loading,
      onChanged: (values) {
        if (_linkFieldName == null) return;
        final rows = values
            .map((v) => <String, dynamic>{_linkFieldName!: v})
            .toList();
        widget.onChanged?.call(rows);
      },
    );
  }
}
