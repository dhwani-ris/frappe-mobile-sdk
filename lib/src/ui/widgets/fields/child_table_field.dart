import 'package:flutter/material.dart';
import '../../../models/doc_field.dart';
import '../../../models/doc_type_meta.dart';
import '../../../services/mobile_creation_capture.dart';
import '../../../utils/mobile_creation_stamp.dart';
import '../screen_helpers.dart';
import 'child_table_cells.dart';

/// Preserves the identity/system columns a child form does not render (e.g.
/// `mobile_uuid`, `name`) from the pre-edit [original] row onto the
/// [submitted] row. The child row's `FormController` seeds `_rawValues` only
/// for docfields, so `buildSubmitData` drops `mobile_uuid`; without this, a
/// re-saved edited child row gets a fresh local PK and its queued attachment
/// row is orphaned. A value already present in [submitted] wins (never
/// overwritten).
Map<String, dynamic> preserveChildIdentity(
  Map<String, dynamic> original,
  Map<String, dynamic> submitted,
) {
  const identityKeys = ['mobile_uuid', 'name'];
  final out = Map<String, dynamic>.from(submitted);
  for (final k in identityKeys) {
    if (out[k] == null && original[k] != null) out[k] = original[k];
  }
  return out;
}

/// Builds the form widget for a child table row (add/edit dialog or bottom sheet).
/// [registerSubmit] is called with the form's submit handler so the host can show Save/Cancel.
typedef ChildTableFormBuilder =
    Widget Function(
      DocTypeMeta childMeta,
      Map<String, dynamic>? initialData,
      void Function(Map<String, dynamic>) onSubmit, {
      void Function(void Function() submit)? registerSubmit,
      bool readOnly,
    });

/// Returns optional guidance to show above a child row form, or null for none.
///
/// [row] is null for the Add sheet and the existing row map for View/Edit, so a
/// host can scope guidance to rows that have not reached the server yet.
typedef ChildRowNoticeBuilder =
    String? Function(
      String childDoctype,
      String parentFieldname,
      Map<String, dynamic>? row,
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
  final String? errorText;

  /// Resolves a Link cell to the linked document's title. Null renders raw ids.
  final LinkTitleResolver? resolveLinkTitle;

  /// Supplies optional guidance rendered above a child row form.
  final ChildRowNoticeBuilder? rowNoticeBuilder;

  /// Captures a NEW row's `mobile_created_at` / `mobile_latitude_longitude`
  /// when Add Row is tapped. Null disables row-level capture entirely.
  final MobileCreationCapture? creationCapture;

  const ChildTableField({
    super.key,
    required this.field,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.getMeta,
    this.formBuilder,
    this.errorText,
    this.resolveLinkTitle,
    this.rowNoticeBuilder,
    this.creationCapture,
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
                // `displayLabel`, not `label ?? fieldname`: server metadata
                // routinely omits a label on child Table fields, and the raw
                // fieldname then becomes the heading an operator reads —
                // "assaying_parameters" instead of "Assaying Parameters".
                // `??` also cannot catch a label that is present but empty or
                // zero-width, which `displayLabel` handles.
                field.displayLabel.isEmpty ? 'Table' : field.displayLabel,
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
                  title: FutureBuilder<_RowDisplay>(
                    future: _rowDisplay(row, index),
                    builder: (context, snap) {
                      final d = snap.data;
                      if (d == null) return const Text('…');
                      if (d.cells.isNotEmpty) return _cellsColumn(d.cells);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(d.title),
                          if (d.subtitle.isNotEmpty)
                            Text(
                              d.subtitle,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      );
                    },
                  ),
                  // The declared columns already carry the values a subtitle
                  // would repeat, so it is folded into the title builder above
                  // and rendered only when the child declares no columns.
                  subtitle: null,
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
                  onTap: () {
                    final isReadOnly =
                        !enabled || field.readOnly || onChanged == null;
                    _showRowDialog(
                      context,
                      index,
                      listValue,
                      row,
                      isReadOnly: isReadOnly,
                    );
                  },
                ),
              );
            },
          ),
        if (errorText != null && errorText!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              errorText!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  /// Stamps the child doctype onto an emitted row.
  ///
  /// A row leaving the sheet otherwise carries only its rendered docfields, so
  /// a consumer that needs to know which child doctype it belongs to has to
  /// infer it from the parent field's options. An explicit value already on the
  /// row wins and is never overwritten.
  Map<String, dynamic> _withDoctype(Map<String, dynamic> row) {
    final doctype = field.options;
    if (doctype == null || doctype.isEmpty) return row;
    if ((row['doctype']?.toString() ?? '').isNotEmpty) return row;
    return {...row, 'doctype': doctype};
  }

  /// Guidance to show above a row form, or null when the host supplies none.
  String? _noticeFor(Map<String, dynamic>? row) =>
      rowNoticeBuilder?.call(field.options ?? '', field.fieldname ?? '', row);

  /// Resolves everything one row needs to render in a single metadata read.
  Future<_RowDisplay> _rowDisplay(Map<String, dynamic> row, int index) async {
    DocTypeMeta? meta;
    try {
      meta = await getMeta?.call(field.options!);
    } catch (_) {
      meta = null;
    }
    final columns = childListViewFields(meta);
    if (columns.isNotEmpty) {
      return _RowDisplay(
        title: '',
        subtitle: '',
        cells: await resolveChildListViewCells(
          row,
          meta,
          columns,
          resolveLinkTitle,
        ),
      );
    }
    return _RowDisplay(
      title: await resolveChildRowTitle(row, meta, index, resolveLinkTitle),
      subtitle: _rowSubtitle(row),
      cells: const <MapEntry<String, String>>[],
    );
  }

  /// One label/value line per declared column.
  ///
  /// Both sides are bounded: a long label would otherwise wrap to three lines,
  /// and a Small Text value is unbounded — a ten-column child then eats a third
  /// of the screen per row.
  Widget _cellsColumn(List<MapEntry<String, String>> cells) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final c in cells)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 4,
                child: Text(
                  c.key,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
              Expanded(
                flex: 6,
                child: Text(
                  c.value,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );

  String _rowSubtitle(Map<String, dynamic> row) {
    final parts = <String>[];
    for (final k in ['amount', 'qty', 'rate']) {
      if (row[k] != null) parts.add('$k: ${row[k]}');
    }
    return parts.join(' | ');
  }


  Future<void> _showAddRowDialog(
    BuildContext context,
    List<dynamic> listValue,
  ) async {
    // The same `onChanged == null` guard the edit-row dialog has at
    // line 213. Without it, the add dialog appears successfully and then
    // crashes when invoking `onChanged!(newList)` after the user submits.
    if (getMeta == null ||
        field.options == null ||
        onChanged == null ||
        formBuilder == null) {
      return;
    }

    DocTypeMeta? childMeta;
    try {
      childMeta = await getMeta!(field.options!);
    } catch (e, st) {
      debugPrint(
        'ChildTableField._showAddRowDialog: getMeta(${field.options}) failed — $e\n$st',
      );
      if (context.mounted) {
        // Original called the bare `SnackBar(content: Text(...))` with no
        // backgroundColor — preserve that neutral styling explicitly.
        showStatusSnackBar(context, 'Error loading form: $e');
      }
      return;
    }
    if (!context.mounted) return;

    // Begin the row's creation capture HERE — the moment Add Row was tapped —
    // not when the row is submitted. The user then spends a few seconds filling
    // the row in, which is exactly the window the GPS read needs, so the wait
    // at submit below is almost always already satisfied.
    final capture = creationCapture;
    final pending = (capture != null && declaresCreationMeta(childMeta))
        ? capture.begin()
        : null;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ChildTableSheet(
        notice: _noticeFor(null),
        title: 'Add ${field.options}',
        childMeta: childMeta!,
        initialData: null,
        isEdit: false,
        formBuilder: formBuilder!,
        onSubmit: (data) async {
          final row = pending == null
              ? data
              : stampCreationMeta(
                  meta: childMeta!,
                  data: data,
                  createdAt: formatFrappeDatetime(pending.startedAt),
                  latitudeLongitude: await pending.location(),
                );
          // Awaited before the pop so the row is complete when the sheet
          // closes; a row handed to `onChanged` after the fact could miss a
          // parent save the user triggers in between.
          if (!ctx.mounted) return;
          Navigator.pop(ctx);
          final newList = List<dynamic>.from(listValue)..add(_withDoctype(row));
          onChanged!(newList);
        },
        onRemove: null,
      ),
    );
  }

  Future<void> _showRowDialog(
    BuildContext context,
    int index,
    List<dynamic> listValue,
    Map<String, dynamic> rowData, {
    bool isReadOnly = false,
  }) async {
    if (getMeta == null ||
        field.options == null ||
        (onChanged == null && !isReadOnly) ||
        formBuilder == null) {
      return;
    }

    DocTypeMeta? childMeta;
    try {
      childMeta = await getMeta!(field.options!);
    } catch (e, st) {
      debugPrint(
        'ChildTableField._showRowDialog: getMeta(${field.options}) failed — $e\n$st',
      );
      if (context.mounted) {
        // Original called the bare `SnackBar(content: Text(...))` with no
        // backgroundColor — preserve that neutral styling explicitly.
        showStatusSnackBar(context, 'Error loading form: $e');
      }
      return;
    }
    if (!context.mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ChildTableSheet(
        notice: _noticeFor(rowData),
        title: isReadOnly ? 'View ${field.options}' : 'Edit ${field.options}',
        childMeta: childMeta!,
        initialData: rowData,
        isEdit: !isReadOnly,
        isReadOnly: isReadOnly,
        formBuilder: formBuilder!,
        onSubmit: isReadOnly
            ? (_) {}
            : (data) {
                Navigator.pop(ctx);
                final newList = List<dynamic>.from(listValue);
                // Carry the row's local identity (mobile_uuid / name) across the
                // edit — the child form does not render those columns and would
                // otherwise drop them, orphaning any queued attachment row.
                newList[index] = _withDoctype(
                  preserveChildIdentity(rowData, data),
                );
                onChanged?.call(newList);
              },
        onRemove: isReadOnly
            ? null
            : () {
                Navigator.pop(ctx);
                final newList = List<dynamic>.from(listValue);
                newList.removeAt(index);
                onChanged?.call(newList);
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
    this.notice,
    this.isReadOnly = false,
    required this.formBuilder,
    required this.onSubmit,
    required this.onRemove,
  });

  final String title;
  final String? notice;
  final DocTypeMeta childMeta;
  final Map<String, dynamic>? initialData;
  final bool isEdit;
  final bool isReadOnly;
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
    final mq = MediaQuery.of(context);
    final bottomInset = mq.viewInsets.bottom;
    // Cap the sheet at 85% of the screen, but never taller than the space
    // left once the on-screen keyboard is shown, so the focused field and
    // the Save/Cancel footer stay visible instead of hiding behind it.
    final maxHeight = mq.size.height * 0.85;
    final available = mq.size.height - bottomInset;
    final height = available < maxHeight ? available : maxHeight;
    return Padding(
      // Lift the sheet above the keyboard (viewInsets grows with it).
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
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
            if ((widget.notice ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    widget.notice!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: widget.formBuilder(
                widget.childMeta,
                widget.initialData,
                (data) => widget.onSubmit(data),
                registerSubmit: widget.isReadOnly
                    ? null
                    : (fn) {
                        final wasUnregistered = _submitFn == null;
                        _submitFn = fn;
                        // Rebuild ONLY on the unregistered -> registered
                        // transition, which is the single moment the action
                        // button has to flip from disabled to enabled.
                        //
                        // Rebuilding on every registration is an unbounded
                        // frame loop: the host calls registerSubmit from
                        // inside its own build, so setState re-enters
                        // formBuilder, which registers again, which schedules
                        // another setState. The sheet never settles —
                        // pumpAndSettle hangs in tests and the render loop
                        // never idles on device.
                        if (!wasUnregistered) return;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) setState(() {});
                        });
                      },
                readOnly: widget.isReadOnly,
              ),
            ),
            const Divider(height: 1),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    if (widget.isEdit &&
                        widget.onRemove != null &&
                        !widget.isReadOnly)
                      TextButton.icon(
                        onPressed: () => widget.onRemove!(),
                        icon: const Icon(Icons.delete_outline, size: 20),
                        label: const Text('Remove'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                      ),
                    if (widget.isEdit &&
                        widget.onRemove != null &&
                        !widget.isReadOnly)
                      const SizedBox(width: 8),
                    const Spacer(),
                    if (widget.isReadOnly)
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      )
                    else ...[
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _submitFn != null
                            ? () => _submitFn!()
                            : null,
                        icon: _submitFn != null
                            ? const Icon(Icons.check, size: 20)
                            : const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              ),
                        label: const Text('Save'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What one child row renders: either a set of declared grid cells, or a
/// title/subtitle pair when the child doctype declares no columns.
class _RowDisplay {
  const _RowDisplay({
    required this.title,
    required this.subtitle,
    required this.cells,
  });

  final String title;
  final String subtitle;
  final List<MapEntry<String, String>> cells;
}
