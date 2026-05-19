// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/utils.dart';
import '../models/doc_type_meta.dart';
import '../models/document.dart';
import '../models/link_filter_result.dart';
import '../models/outbox_row.dart';
import '../query/unified_resolver.dart';
import '../services/link_option_service.dart';
import '../services/meta_service.dart';
import '../services/offline_repository.dart';
import '../services/permission_service.dart';
import '../services/sync_controller.dart';
import '../services/sync_service.dart';
import 'form_screen.dart';
import 'widgets/form_builder.dart'
    show FrappeFormStyle, OnButtonPressedCallback, FieldChangeHandler;
import 'widgets/sync_error_banner.dart' show humanizeOutboxError;

/// Layout variants for [DocumentListScreen].
enum DocumentListLayout { list, card }

/// Visual customization for [DocumentListScreen].
class DocumentListStyle {
  final DocumentListLayout layout;
  final Color? cardColor;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;
  final ButtonStyle? primaryButtonStyle;
  final Color? fabBackgroundColor;
  final Color? fabForegroundColor;

  const DocumentListStyle({
    this.layout = DocumentListLayout.list,
    this.cardColor,
    this.titleStyle,
    this.subtitleStyle,
    this.primaryButtonStyle,
    this.fabBackgroundColor,
    this.fabForegroundColor,
  });
}

/// SDK document list screen with search, sort, and pagination.
/// Uses [DocTypeMeta.titleField], [DocTypeMeta.sortField], [DocTypeMeta.sortOrder]
/// and list view fields from metadata.
class DocumentListScreen extends StatefulWidget {
  final String doctype;
  final DocTypeMeta meta;
  final OfflineRepository repository;
  final UnifiedResolver resolver;
  final SyncService syncService;
  final MetaService metaService;
  final LinkOptionService? linkOptionService;
  final FrappeClient? api;
  final Future<String?> Function()? getMobileUuid;

  /// Optional: current user's roles for permission evaluation (fallback when [permissionService] is null).
  final List<String>? userRoles;

  /// Optional: when set, create/write/delete are resolved from backend permissions (login / mobile_auth.permissions).
  final PermissionService? permissionService;

  /// If set, doctype label and field labels are translated (e.g. sdk.translations.translate).
  final String Function(String)? translate;

  /// Optional initial documents; if null, list is fetched on load.
  final List<Document>? initialDocuments;

  /// Optional callback when a Button field is pressed in the form. Override to implement client-script logic.
  final OnButtonPressedCallback? onButtonPressed;

  /// Called when a field value changes in the form. Returns computed field patches.
  final FieldChangeHandler? onFieldChange;

  /// Optional builder for runtime link filters. Called during link option resolution.
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
  getLinkFilterBuilder;

  /// Optional customization for list UI (layout, colors, typography, button style).
  final DocumentListStyle? style;

  /// Optional form style passed to opened [FormScreen].
  final FrappeFormStyle? formStyle;

  /// Optional form screen style passed to opened [FormScreen].
  final FormScreenStyle? formScreenStyle;

  /// Imperative sync surface. When provided, list rows whose
  /// `mobile_uuid` has a stuck outbox row (failed/blocked/conflict)
  /// render a per-row error indicator, and the opened [FormScreen]
  /// receives the same controller so its banner can offer Retry.
  final SyncController? syncController;

  const DocumentListScreen({
    super.key,
    required this.doctype,
    required this.meta,
    required this.repository,
    required this.resolver,
    required this.syncService,
    required this.metaService,
    this.linkOptionService,
    this.api,
    this.getMobileUuid,
    this.initialDocuments,
    this.userRoles,
    this.permissionService,
    this.translate,
    this.onButtonPressed,
    this.onFieldChange,
    this.getLinkFilterBuilder,
    this.style,
    this.formStyle,
    this.formScreenStyle,
    this.syncController,
  });

  @override
  State<DocumentListScreen> createState() => _DocumentListScreenState();
}

class _DocumentListScreenState extends State<DocumentListScreen> {
  List<Document> _documents = [];
  final bool _isLoading = false;
  bool _isSyncing = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String? _sortField;
  bool _sortAsc = true;
  int _page = 0;
  static const int _pageSize = 20;

  bool? _permCreate;
  bool? _permWrite;
  bool? _permDelete;

  /// Stuck outbox rows for the current doctype, indexed by `mobile_uuid`.
  /// Filled in [_pullDocuments] from a single
  /// [SyncController.pendingErrors] query rather than one query per row.
  /// A `mobile_uuid` may map to multiple rows (e.g., a blocked INSERT
  /// followed by a queued UPDATE) — the worst-priority state drives the
  /// per-row indicator.
  final Map<String, List<OutboxRow>> _errorsByUuid =
      <String, List<OutboxRow>>{};

  bool get _canCreate =>
      _permCreate ??
      widget.meta.hasPermission('create', userRoles: widget.userRoles);
  bool get _canWrite =>
      _permWrite ??
      widget.meta.hasPermission('write', userRoles: widget.userRoles);
  bool get _canDelete =>
      _permDelete ??
      widget.meta.hasPermission('delete', userRoles: widget.userRoles);

  @override
  void initState() {
    super.initState();
    _documents = List.from(widget.initialDocuments ?? []);
    _sortField = widget.meta.sortField ?? 'modified';
    _sortAsc = widget.meta.sortOrder != 'desc';
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
        _page = 0;
      });
    });
    _loadPermissions();
    _pullDocuments();
  }

  Future<void> _loadPermissions() async {
    final ps = widget.permissionService;
    if (ps == null) return;
    final c = await ps.canCreate(widget.doctype);
    final w = await ps.canWrite(widget.doctype);
    final d = await ps.canDelete(widget.doctype);
    if (!mounted) return;
    setState(() {
      _permCreate = c;
      _permWrite = w;
      _permDelete = d;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _getFieldLabel(String fieldname) {
    final field = widget.meta.getField(fieldname);
    String raw;
    if (field != null && field.label != null && field.label!.isNotEmpty) {
      raw = field.label!;
    } else {
      raw = fieldname
          .replaceAll('_', ' ')
          .split(' ')
          .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
          .join(' ');
    }
    return widget.translate != null ? widget.translate!(raw) : raw;
  }

  String _docTitle(Document doc) {
    final titleFieldName = widget.meta.titleField;
    if (titleFieldName != null &&
        titleFieldName.isNotEmpty &&
        doc.data[titleFieldName] != null) {
      return doc.data[titleFieldName].toString().trim();
    }
    final t =
        doc.data['title']?.toString() ?? doc.data['name']?.toString() ?? '';
    if (t.isNotEmpty) return t;
    for (final fn in [
      'full_name',
      'customer_name',
      'supplier_name',
      'item_name',
      'item_code',
    ]) {
      final v = doc.data[fn]?.toString();
      if (v != null && v.isNotEmpty) return v;
    }
    return doc.serverId ?? doc.localId;
  }

  List<Document> _filteredAndSortedDocs() {
    var list = _documents.where((doc) {
      if (_searchQuery.isEmpty) return true;
      final title = _docTitle(doc).toLowerCase();
      final id = (doc.serverId ?? doc.localId).toLowerCase();
      final status = (doc.data['status']?.toString() ?? '').toLowerCase();
      return title.contains(_searchQuery) ||
          id.contains(_searchQuery) ||
          status.contains(_searchQuery);
    }).toList();
    final field = _sortField ?? 'modified';
    final asc = _sortAsc;
    list.sort((a, b) {
      final av = a.data[field];
      final bv = b.data[field];
      if (av == null && bv == null) return 0;
      if (av == null) return asc ? 1 : -1;
      if (bv == null) return asc ? -1 : 1;
      final cmp = (av is num && bv is num)
          ? (av).compareTo(bv)
          : av.toString().compareTo(bv.toString());
      return asc ? cmp : -cmp;
    });
    return list;
  }

  Future<void> _pullDocuments() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    try {
      final isOnline = await widget.syncService.isOnline();
      if (isOnline) {
        try {
          await widget.syncService.pullSync(doctype: widget.doctype);
        } catch (e, st) {
          // ignore: avoid_print
          print(
            'DocumentListScreen: pullSync(${widget.doctype}) failed — $e\n$st',
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Sync failed: ${toUserFriendlyMessage(e)}'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
      final docs = await _fetchViaResolver();
      await _refreshErrorIndex();
      if (mounted) setState(() => _documents = docs);
    } catch (e, st) {
      // ignore: avoid_print
      print('DocumentListScreen: _pullDocuments failed — $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to load documents: ${toUserFriendlyMessage(e)}',
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  /// Repopulates [_errorsByUuid] from `syncController.pendingErrors()`.
  /// Best-effort: a query failure leaves the map empty rather than
  /// blocking the list render. No-op when the list screen was hosted
  /// without a SyncController.
  Future<void> _refreshErrorIndex() async {
    final controller = widget.syncController;
    _errorsByUuid.clear();
    if (controller == null) return;
    try {
      final all = await controller.pendingErrors();
      for (final r in all) {
        if (r.doctype != widget.doctype) continue;
        _errorsByUuid.putIfAbsent(r.mobileUuid, () => <OutboxRow>[]).add(r);
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('DocumentListScreen: pendingErrors load failed — $e\n$st');
    }
  }

  Future<List<Document>> _fetchViaResolver() async {
    final result = await widget.resolver.resolve(
      doctype: widget.doctype,
      page: 0,
      pageSize: 100,
    );
    return result.rows
        .map((row) => Document.fromResolverRow(widget.doctype, row))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final listStyle = widget.style ?? const DocumentListStyle();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.translate != null
              ? widget.translate!(widget.meta.label ?? widget.doctype)
              : (widget.meta.label ?? widget.doctype),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            onSelected: (value) {
              setState(() {
                if (value == _sortField) {
                  _sortAsc = !_sortAsc;
                } else {
                  _sortField = value;
                  _sortAsc = true;
                }
                _page = 0;
              });
            },
            itemBuilder: (context) {
              final sortableFields = <String>{};
              if (widget.meta.titleField != null &&
                  widget.meta.titleField!.isNotEmpty) {
                sortableFields.add(widget.meta.titleField!);
              }
              for (final field in widget.meta.listViewFields) {
                if (field.fieldname != null &&
                    field.fieldname!.isNotEmpty &&
                    field.isDataField &&
                    !field.hidden) {
                  sortableFields.add(field.fieldname!);
                }
              }
              sortableFields.addAll(['name', 'modified', 'creation']);
              final fields = sortableFields.toList()..sort();
              return [
                for (final f in fields)
                  PopupMenuItem<String>(
                    value: f,
                    child: Row(
                      children: [
                        Expanded(child: Text(_getFieldLabel(f))),
                        if (_sortField == f)
                          Icon(
                            _sortAsc
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                      ],
                    ),
                  ),
              ];
            },
          ),
          if (_isSyncing)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _pullDocuments,
              tooltip: 'Refresh',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _documents.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              onRefresh: _pullDocuments,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search...',
                        prefixIcon: const Icon(Icons.search),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  Expanded(child: _buildList()),
                ],
              ),
            ),
      floatingActionButton: _canCreate
          ? FloatingActionButton(
              onPressed: () => _openForm(null),
              backgroundColor: listStyle.fabBackgroundColor,
              foregroundColor: listStyle.fabForegroundColor,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildEmptyState() {
    final listStyle = widget.style ?? const DocumentListStyle();
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.inbox, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('No documents found'),
          const SizedBox(height: 8),
          Text(
            'Pull down to refresh or create a new document',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _pullDocuments,
            style: listStyle.primaryButtonStyle,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh from Server'),
          ),
          if (_canCreate) ...[
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _openForm(null),
              style: listStyle.primaryButtonStyle,
              icon: const Icon(Icons.add),
              label: const Text('Create New'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildList() {
    final listStyle = widget.style ?? const DocumentListStyle();
    final full = _filteredAndSortedDocs();
    final total = full.length;
    final start = _page * _pageSize;
    final pageList = start < total
        ? full.sublist(start, (start + _pageSize).clamp(0, total))
        : <Document>[];
    final totalPages = (total / _pageSize).ceil().clamp(1, 0x7fffffff);

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: pageList.length,
            itemBuilder: (context, index) {
              final doc = pageList[index];
              final titleText = _docTitle(doc).isEmpty
                  ? 'Untitled'
                  : _docTitle(doc);
              final idText = doc.serverId != null
                  ? 'ID: ${doc.serverId}'
                  : 'Local (not synced)';
              final hasStatusField = widget.meta.getField('status') != null;
              final statusValue = hasStatusField
                  ? doc.data['status']?.toString()
                  : null;
              final showStatus =
                  statusValue != null &&
                  statusValue.isNotEmpty &&
                  statusValue != 'null';

              final errorRows = _errorsByUuid[doc.localId];
              final hasError = errorRows != null && errorRows.isNotEmpty;
              final trailing = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showStatus)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Chip(
                        label: Text(
                          statusValue,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                        padding: EdgeInsets.zero,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  if (hasError)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: _RowSyncErrorBadge(row: errorRows.first),
                    ),
                  if (doc.status == 'dirty' && !hasError)
                    const Icon(
                      Icons.cloud_upload,
                      color: Colors.orange,
                      size: 20,
                    ),
                  const Icon(Icons.chevron_right),
                ],
              );

              if (listStyle.layout == DocumentListLayout.card) {
                return Card(
                  color: listStyle.cardColor,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: ListTile(
                    title: Text(titleText, style: listStyle.titleStyle),
                    subtitle: Text(idText, style: listStyle.subtitleStyle),
                    trailing: trailing,
                    onTap: () => _openForm(doc),
                  ),
                );
              }

              return ListTile(
                title: Text(titleText, style: listStyle.titleStyle),
                subtitle: Text(idText, style: listStyle.subtitleStyle),
                trailing: trailing,
                onTap: () => _openForm(doc),
              );
            },
          ),
        ),
        if (total > _pageSize)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _page > 0 ? () => setState(() => _page--) : null,
                ),
                Text(
                  'Page ${_page + 1} of $totalPages',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _page < totalPages - 1
                      ? () => setState(() => _page++)
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _openForm(Document? doc) async {
    final isNew = doc == null;
    // Guard against navigation when user lacks permissions
    if (isNew && !_canCreate) return;
    if (!isNew && !_canWrite) return;

    // For existing records in online mode: fetch the full document from the
    // server before opening the form, because list queries only fetch display
    // fields. In offline mode the document already has all parent fields from
    // pullSync but child rows live in separate per-doctype tables — attach
    // them now so the form builder receives the embedded child arrays.
    Document? resolvedDoc = doc;
    final isOffline = widget.repository.offlineMode.enabled;
    if (!isNew && isOffline) {
      try {
        resolvedDoc = await widget.repository.attachChildRows(
          widget.doctype,
          doc,
          widget.meta,
        );
      } catch (e, st) {
        debugPrint(
          'DocumentListScreen: attachChildRows(${widget.doctype}) failed — $e\n$st',
        );
        resolvedDoc = doc;
      }
    } else if (!isNew &&
        !isOffline &&
        doc.serverId != null &&
        widget.api != null) {
      setState(() => _isSyncing = true);
      try {
        final freshData = await widget.api!.doctype.getByName(
          widget.doctype,
          doc.serverId!,
        );
        // Mirror fresh server data into docs__<doctype> so it's available
        // offline too. applyServerDocument respects local sync_status —
        // dirty/conflict rows are skipped to preserve unsynced edits.
        try {
          await widget.repository.applyServerDocument(
            doctype: widget.doctype,
            serverName: doc.serverId!,
            data: freshData,
          );
        } catch (e, st) {
          // Mirror is best-effort; the fresh data still drives the form.
          // ignore: avoid_print
          print(
            'document_list_screen: applyServerDocument mirror failed for '
            '${widget.doctype}/${doc.serverId} — $e\n$st',
          );
        }
        resolvedDoc = Document.fromServer(
          doctype: widget.doctype,
          serverId: doc.serverId!,
          data: freshData,
          localId: doc.localId,
        );
      } catch (e, st) {
        // Network error — fall back to local cached data.
        debugPrint(
          'DocumentListScreen: getByName(${widget.doctype}/${doc.serverId}) failed — $e\n$st',
        );
        resolvedDoc = doc;
      } finally {
        if (mounted) setState(() => _isSyncing = false);
      }
    }

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FormScreen(
          meta: widget.meta,
          document: resolvedDoc,
          repository: widget.repository,
          syncService: widget.syncService,
          linkOptionService: widget.linkOptionService,
          metaService: widget.metaService,
          api: widget.api,
          onSaveSuccess: () {
            Navigator.pop(context);
            _pullDocuments();
          },
          getMobileUuid: widget.getMobileUuid,
          onButtonPressed: widget.onButtonPressed,
          onFieldChange: widget.onFieldChange,
          getLinkFilterBuilder: widget.getLinkFilterBuilder,
          style: widget.formStyle,
          screenStyle: widget.formScreenStyle,
          syncController: widget.syncController,
          // Permissions
          readOnly: !isNew && !_canWrite,
          canSave: isNew ? _canCreate : _canWrite,
          canDelete: !isNew && _canDelete,
          translate: widget.translate,
        ),
      ),
    ).then((_) {
      // Banner state may have changed inside the form (retry tapped,
      // save resolved a stuck row); refresh the per-row error index.
      _refreshErrorIndex().then((_) {
        if (mounted) setState(() {});
      });
    });
  }
}

/// Compact icon that shows a colour cue + a tooltip with the
/// human-readable headline. Tapping the row opens the form which has
/// the full expandable banner.
class _RowSyncErrorBadge extends StatelessWidget {
  final OutboxRow row;
  const _RowSyncErrorBadge({required this.row});

  @override
  Widget build(BuildContext context) {
    final headline = humanizeOutboxError(row).headline;
    final IconData icon;
    final Color color;
    switch (row.state) {
      case OutboxState.blocked:
        icon = Icons.hourglass_top_outlined;
        color = const Color(0xFF8D6E00);
        break;
      case OutboxState.conflict:
        icon = Icons.merge_type;
        color = const Color(0xFFC62828);
        break;
      case OutboxState.failed:
        icon = Icons.error_outline;
        color = const Color(0xFFC62828);
        break;
      case OutboxState.pending:
      case OutboxState.inFlight:
      case OutboxState.done:
        icon = Icons.sync;
        color = Colors.grey;
        break;
    }
    return Tooltip(
      message: headline,
      child: Icon(icon, color: color, size: 20),
    );
  }
}
