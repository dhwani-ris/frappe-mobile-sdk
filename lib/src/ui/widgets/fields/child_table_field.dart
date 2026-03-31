import 'package:flutter/material.dart';
import '../../../models/doc_field.dart';
import '../../../models/doc_type_meta.dart';

/// Builds the form widget for a child table row (add/edit dialog or bottom sheet).
/// [registerSubmit] is called with the form's submit handler so the host can show Save/Cancel.
typedef ChildTableFormBuilder =
    Widget Function(
      DocTypeMeta childMeta,
      Map<String, dynamic>? initialData,
      void Function(Map<String, dynamic>) onSubmit, {
      void Function(void Function() submit)? registerSubmit,
    });

/// Widget for Table (child table) field type.
/// Shows a list of rows; Add/Edit open a dialog with the form built by [formBuilder].
class ChildTableField extends StatelessWidget {
  final DocField field;
  final List<dynamic> value;
  final ValueChanged<List<dynamic>>? onChanged;
  final bool enabled;
  final Future<DocTypeMeta> Function(String doctype)? getMeta;
  final ChildTableFormBuilder? formBuilder;

  const ChildTableField({
    super.key,
    required this.field,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.getMeta,
    this.formBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final listValue = value;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                field.label ?? field.fieldname ?? 'Table',
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
              ),
            ),
            if (enabled && !field.readOnly && onChanged != null)
              TextButton.icon(
                onPressed: () => _showAddRowDialog(context, listValue),
                icon: const Icon(Icons.add, size: 20),
                label: const Text('Add Row'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (listValue.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                'No records added',
                style: TextStyle(color: Colors.grey.shade600),
              ),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: listValue.length,
            itemBuilder: (context, index) {
              final row = listValue[index] is Map<String, dynamic>
                  ? listValue[index] as Map<String, dynamic>
                  : <String, dynamic>{};
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: FutureBuilder<String>(
                    future: _rowTitle(row),
                    builder: (_, snap) => Text(snap.data ?? '…'),
                  ),
                  subtitle: _rowSubtitle(row).isNotEmpty
                      ? Text(_rowSubtitle(row))
                      : null,
                  trailing: enabled && !field.readOnly && onChanged != null
                      ? IconButton(
                          icon: const Icon(Icons.delete, color: Colors.red),
                          onPressed: () {
                            final newList = List<dynamic>.from(listValue);
                            newList.removeAt(index);
                            onChanged!(newList);
                          },
                        )
                      : null,
                  onTap: enabled && !field.readOnly && onChanged != null
                      ? () => _showEditRowDialog(context, index, listValue, row)
                      : null,
                ),
              );
            },
          ),
      ],
    );
  }

  Future<String> _rowTitle(Map<String, dynamic> row) async {
    final meta = await getMeta?.call(field.options!);
    // Use the doctype's configured title_field first
    if (meta != null &&
        meta.titleField != null &&
        meta.titleField!.isNotEmpty) {
      final v = row[meta.titleField!];
      if (v != null && v.toString().isNotEmpty) return v.toString();
    }
    // Common name fields (excluding 'name' which is a raw server ID)
    final prefer = ['item_name', 'item_code', 'bank_name', 'name'];
    for (final k in prefer) {
      if (row[k] != null && row[k].toString().isNotEmpty) {
        return row[k].toString();
      }
    }
    for (final e in row.entries) {
      if (!_isSystemKey(e.key) &&
          e.value != null &&
          e.value.toString().isNotEmpty) {
        return '${e.key}: ${e.value}';
      }
    }
    return 'Row ${row.hashCode % 1000}';
  }

  String _rowSubtitle(Map<String, dynamic> row) {
    final parts = <String>[];
    for (final k in ['amount', 'qty', 'rate']) {
      if (row[k] != null) parts.add('$k: ${row[k]}');
    }
    return parts.join(' | ');
  }

  bool _isSystemKey(String key) {
    return [
      'name',
      'owner',
      'creation',
      'modified',
      'docstatus',
      'idx',
      'doctype',
    ].contains(key);
  }

  Future<void> _showAddRowDialog(
    BuildContext context,
    List<dynamic> listValue,
  ) async {
    if (getMeta == null || field.options == null || formBuilder == null) return;

    DocTypeMeta? childMeta;
    try {
      childMeta = await getMeta!(field.options!);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading form: $e')));
      }
      return;
    }
    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ChildTableSheet(
        title: 'Add ${field.options}',
        childMeta: childMeta!,
        initialData: null,
        isEdit: false,
        formBuilder: formBuilder!,
        onSubmit: (data) {
          Navigator.pop(ctx);
          final newList = List<dynamic>.from(listValue)..add(data);
          onChanged!(newList);
        },
        onRemove: null,
      ),
    );
  }

  Future<void> _showEditRowDialog(
    BuildContext context,
    int index,
    List<dynamic> listValue,
    Map<String, dynamic> rowData,
  ) async {
    if (getMeta == null ||
        field.options == null ||
        onChanged == null ||
        formBuilder == null) {
      return;
    }

    DocTypeMeta? childMeta;
    try {
      childMeta = await getMeta!(field.options!);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error loading form: $e')));
      }
      return;
    }
    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ChildTableSheet(
        title: 'Edit ${field.options}',
        childMeta: childMeta!,
        initialData: rowData,
        isEdit: true,
        formBuilder: formBuilder!,
        onSubmit: (data) {
          Navigator.pop(ctx);
          final newList = List<dynamic>.from(listValue);
          newList[index] = data;
          onChanged!(newList);
        },
        onRemove: () {
          Navigator.pop(ctx);
          final newList = List<dynamic>.from(listValue);
          newList.removeAt(index);
          onChanged!(newList);
        },
      ),
    );
  }
}

/// Content for child table add/edit modal bottom sheet with Save, Cancel, Remove.
class _ChildTableSheet extends StatefulWidget {
  const _ChildTableSheet({
    required this.title,
    required this.childMeta,
    required this.initialData,
    required this.isEdit,
    required this.formBuilder,
    required this.onSubmit,
    required this.onRemove,
  });

  final String title;
  final DocTypeMeta childMeta;
  final Map<String, dynamic>? initialData;
  final bool isEdit;
  final ChildTableFormBuilder formBuilder;
  final void Function(Map<String, dynamic>) onSubmit;
  final void Function()? onRemove;

  @override
  State<_ChildTableSheet> createState() => _ChildTableSheetState();
}

class _ChildTableSheetState extends State<_ChildTableSheet> {
  void Function()? _submitFn;

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height * 0.85;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: widget.formBuilder(
              widget.childMeta,
              widget.initialData,
              (data) => widget.onSubmit(data),
              registerSubmit: (fn) {
                _submitFn = fn;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
              },
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  if (widget.isEdit && widget.onRemove != null)
                    TextButton.icon(
                      onPressed: () => widget.onRemove!(),
                      icon: const Icon(Icons.delete_outline, size: 20),
                      label: const Text('Remove'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
                    ),
                  if (widget.isEdit && widget.onRemove != null)
                    const SizedBox(width: 8),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _submitFn != null ? () => _submitFn!() : null,
                    icon: const Icon(Icons.check, size: 20),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
