// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:flutter/material.dart';
import '../api/client.dart';
import '../models/doc_type_meta.dart';
import '../models/document.dart';
import '../services/offline_repository.dart';
import '../services/sync_service.dart';
import '../services/link_option_service.dart';
import '../services/meta_service.dart';
import 'form_screen.dart';

/// SDK document list screen with search, sort, and pagination.
/// Uses [DocTypeMeta.titleField], [DocTypeMeta.sortField], [DocTypeMeta.sortOrder]
/// and list view fields from metadata.
class DocumentListScreen extends StatefulWidget {
  final String doctype;
  final DocTypeMeta meta;
  final OfflineRepository repository;
  final SyncService syncService;
  final MetaService metaService;
  final LinkOptionService? linkOptionService;
  final FrappeClient? api;
  final Future<String?> Function()? getMobileUuid;

  /// Optional: current user's roles for permission evaluation.
  final List<String>? userRoles;

  /// Optional initial documents; if null, list is fetched on load.
  final List<Document>? initialDocuments;

  const DocumentListScreen({
    super.key,
    required this.doctype,
    required this.meta,
    required this.repository,
    required this.syncService,
    required this.metaService,
    this.linkOptionService,
    this.api,
    this.getMobileUuid,
    this.initialDocuments,
    this.userRoles,
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

  bool get _canCreate =>
      widget.meta.hasPermission('create', userRoles: widget.userRoles);
  bool get _canWrite =>
      widget.meta.hasPermission('write', userRoles: widget.userRoles);
  bool get _canDelete =>
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
    _pullDocuments();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _getFieldLabel(String fieldname) {
    final field = widget.meta.getField(fieldname);
    if (field != null && field.label != null && field.label!.isNotEmpty) {
      return field.label!;
    }
    return fieldname
        .replaceAll('_', ' ')
        .split(' ')
        .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
        .join(' ');
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
        await widget.syncService.pullSync(doctype: widget.doctype);
      }
      final docs = await widget.repository.getDocumentsByDoctype(
        widget.doctype,
      );
      setState(() => _documents = docs);
    } catch (e) {
      try {
        final docs = await widget.repository.getDocumentsByDoctype(
          widget.doctype,
        );
        setState(() => _documents = docs);
      } catch (_) {}
    } finally {
      setState(() => _isSyncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.meta.label ?? widget.doctype),
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
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Widget _buildEmptyState() {
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
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh from Server'),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _openForm(null),
            icon: const Icon(Icons.add),
            label: const Text('Create New'),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
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

              return ListTile(
                title: Text(titleText),
                subtitle: Text(idText),
                trailing: Row(
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
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    if (doc.status == 'dirty')
                      const Icon(
                        Icons.cloud_upload,
                        color: Colors.orange,
                        size: 20,
                      ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
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

  void _openForm(Document? doc) {
    final isNew = doc == null;
    // Guard against navigation when user lacks permissions
    if (isNew && !_canCreate) return;
    if (!isNew && !_canWrite) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FormScreen(
          meta: widget.meta,
          document: doc,
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
          // Permissions
          readOnly: !isNew && !_canWrite,
          canSave: isNew ? _canCreate : _canWrite,
          canDelete: !isNew && _canDelete,
        ),
      ),
    );
  }
}
