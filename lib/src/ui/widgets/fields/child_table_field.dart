import 'package:flutter/material.dart';
import '../../../models/doc_field.dart';
import '../../../models/doc_type_meta.dart';

/// Builds the form widget for a child table row (add/edit dialog).
typedef ChildTableFormBuilder =
    Widget Function(
      DocTypeMeta childMeta,
      Map<String, dynamic>? initialData,
      void Function(Map<String, dynamic>) onSubmit,
    );

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
            Text(
              field.label ?? field.fieldname ?? 'Table',
              style: Theme.of(context).textTheme.titleMedium,
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
                  title: Text(_rowTitle(row)),
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

  String _rowTitle(Map<String, dynamic> row) {
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

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Container(
          width: 500,
          height: 500,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Add ${field.options}',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: formBuilder!(childMeta!, null, (data) {
                  final newList = List<dynamic>.from(listValue)..add(data);
                  onChanged!(newList);
                  Navigator.pop(ctx);
                }),
              ),
            ],
          ),
        ),
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

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: Container(
          width: 500,
          height: 500,
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Edit ${field.options}',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              Expanded(
                child: formBuilder!(childMeta!, rowData, (data) {
                  final newList = List<dynamic>.from(listValue);
                  newList[index] = data;
                  onChanged!(newList);
                  Navigator.pop(ctx);
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
