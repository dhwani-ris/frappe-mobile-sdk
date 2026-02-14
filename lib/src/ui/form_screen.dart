import 'package:flutter/material.dart';
import '../api/client.dart';
import '../api/exceptions.dart';
import '../api/utils.dart';
import '../models/doc_type_meta.dart';
import '../models/document.dart';
import '../services/offline_repository.dart';
import '../services/sync_service.dart';
import '../services/link_option_service.dart';
import '../services/meta_service.dart';
import 'widgets/form_builder.dart';
import 'sync_status_screen.dart';

/// Screen for displaying and editing a Frappe document form.
/// When [api] is set, CRUD is done directly on the server then local repo is updated.
class FormScreen extends StatefulWidget {
  final DocTypeMeta meta;
  final Document? document;
  final OfflineRepository repository;
  final SyncService? syncService;
  final LinkOptionService? linkOptionService;
  final MetaService? metaService;

  /// When set, save/delete go to server first; local repo is updated after success.
  final FrappeClient? api;
  final Function()? onSaveSuccess;

  /// When set, new documents created from this screen will include mobile_uuid on the server.
  final Future<String?> Function()? getMobileUuid;

  /// Optional form style (overrides the default style used by FrappeFormBuilder).
  final FrappeFormStyle? style;

  /// Force read-only mode (no editing, no save/delete).
  final bool readOnly;

  /// Explicit permission flags for save/delete buttons. If null, defaults to allowed.
  final bool? canSave;
  final bool? canDelete;

  /// If set, doctype label and field labels are translated (e.g. sdk.translations.translate).
  final String Function(String)? translate;

  const FormScreen({
    super.key,
    required this.meta,
    this.document,
    required this.repository,
    this.syncService,
    this.linkOptionService,
    this.metaService,
    this.api,
    this.onSaveSuccess,
    this.getMobileUuid,
    this.style,
    this.readOnly = false,
    this.canSave,
    this.canDelete,
    this.translate,
  });

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  bool _isSaving = false;
  String? _errorMessage;
  void Function()? _triggerSubmit;

  Future<Map<String, dynamic>?> _fetchLinkedDocument(
    String linkedDoctype,
    String docName,
  ) async {
    try {
      final doc = await widget.repository.getDocumentByServerId(
        docName,
        linkedDoctype,
      );
      if (doc != null) return doc.data;
    } catch (_) {}
    if (widget.api != null) {
      try {
        return await widget.api!.doctype.getByName(linkedDoctype, docName);
      } catch (_) {}
    }
    return null;
  }

  Future<void> _handleSubmit(Map<String, dynamic> formData) async {
    // Normalize multi-select: Frappe expects comma-separated string
    final payload = Map<String, dynamic>.from(formData);
    for (final f in widget.meta.fields) {
      final name = f.fieldname;
      if (f.allowMultiple && name != null && payload[name] is List) {
        payload[name] = (payload[name] as List)
            .map((e) => e.toString())
            .join(',');
      }
    }

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      if (widget.api != null) {
        // Server-first: create/update on server, then update local
        if (widget.document == null) {
          if (widget.getMobileUuid != null) {
            final uuid = await widget.getMobileUuid!();
            if (uuid != null && uuid.isNotEmpty) {
              payload['mobile_uuid'] = uuid;
            }
          }
          final result = await widget.api!.document.createDocument(
            widget.meta.name,
            payload,
          );
          final serverName =
              result['name']?.toString() ?? result['docname']?.toString();
          if (serverName != null) {
            final merged = Map<String, dynamic>.from(payload)
              ..['name'] = serverName;
            await widget.repository.saveServerDocument(
              doctype: widget.meta.name,
              serverId: serverName,
              data: merged,
            );
          }
        } else {
          final existingData = Map<String, dynamic>.from(widget.document!.data);
          existingData.addAll(payload);
          await widget.api!.document.updateDocument(
            widget.meta.name,
            widget.document!.serverId!,
            existingData,
          );
          await widget.repository.updateDocumentData(
            widget.document!.localId,
            existingData,
          );
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved successfully'),
              backgroundColor: Colors.green,
            ),
          );
          widget.onSaveSuccess?.call();
        }
        return;
      }

      // Offline / store-then-sync path
      if (widget.document == null) {
        if (widget.getMobileUuid != null) {
          final uuid = await widget.getMobileUuid!();
          if (uuid != null && uuid.isNotEmpty) {
            payload['mobile_uuid'] = uuid;
          }
        }
        await widget.repository.createDocument(
          doctype: widget.meta.name,
          data: payload,
        );
      } else {
        final existingData = Map<String, dynamic>.from(widget.document!.data);
        existingData.addAll(payload);
        await widget.repository.updateDocumentData(
          widget.document!.localId,
          existingData,
        );
      }

      if (widget.syncService != null) {
        final isOnline = await widget.syncService!.isOnline();
        if (isOnline) {
          try {
            final syncResult = await widget.syncService!.pushSync(
              doctype: widget.meta.name,
            );
            if (mounted) {
              if (syncResult.errors.isNotEmpty) {
                _showSyncErrorDialog(syncResult.errors);
              } else if (syncResult.failed > 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Saved locally. ${syncResult.failed} update(s) failed to sync.',
                    ),
                    backgroundColor: Colors.orange,
                    action: SnackBarAction(
                      label: 'Details',
                      textColor: Colors.white,
                      onPressed: () => _showSyncErrorDialog(syncResult.errors),
                    ),
                  ),
                );
              } else if (syncResult.success > 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Saved and synced (${syncResult.success} document(s))',
                    ),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Saved locally. Sync failed: ${e.toString()}'),
                  backgroundColor: Colors.orange,
                  duration: const Duration(seconds: 3),
                  action: SnackBarAction(
                    label: 'View Status',
                    textColor: Colors.white,
                    onPressed: () {
                      if (widget.syncService != null) {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => SyncStatusScreen(
                              syncService: widget.syncService!,
                              repository: widget.repository,
                            ),
                          ),
                        );
                      }
                    },
                  ),
                ),
              );
            }
          }
        } else if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Saved locally. Will sync when online.'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 2),
            ),
          );
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Document saved successfully'),
            backgroundColor: Colors.green,
          ),
        );
        widget.onSaveSuccess?.call();
      }
    } catch (e) {
      setState(() {
        _errorMessage = e is FrappeException
            ? e.message
            : toUserFriendlyMessage(e);
      });
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  Future<void> _handleDelete() async {
    if (widget.document == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Document'),
        content: const Text('Are you sure you want to delete this document?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _isSaving = true;
    });

    try {
      if (widget.api != null && widget.document!.serverId != null) {
        await widget.api!.document.deleteDocument(
          widget.meta.name,
          widget.document!.serverId!,
        );
        await widget.repository.hardDeleteDocument(widget.document!.localId);
      } else {
        await widget.repository.deleteDocument(widget.document!.localId);
        if (widget.syncService != null) {
          final isOnline = await widget.syncService!.isOnline();
          if (isOnline) {
            try {
              await widget.syncService!.pushSync(doctype: widget.meta.name);
            } catch (_) {}
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Document deleted'),
            backgroundColor: Colors.orange,
          ),
        );
        Navigator.pop(context);
        widget.onSaveSuccess?.call();
      }
    } catch (e) {
      setState(() {
        _errorMessage = e is FrappeException
            ? e.message
            : toUserFriendlyMessage(e);
      });
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  void _showSyncErrorDialog(List<SyncError> errors) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.error, color: Colors.red),
            SizedBox(width: 8),
            Text('Sync Errors'),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: errors.length,
            itemBuilder: (context, index) {
              final error = errors[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                color: Colors.red[50],
                child: ListTile(
                  leading: const Icon(Icons.error_outline, color: Colors.red),
                  title: Text(
                    '${error.operation.toUpperCase()}: ${error.doctype}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Document: ${error.documentId}'),
                      const SizedBox(height: 4),
                      Text(
                        error.errorMessage,
                        style: TextStyle(fontSize: 12, color: Colors.red[700]),
                      ),
                    ],
                  ),
                  isThreeLine: true,
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
          if (widget.syncService != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SyncStatusScreen(
                      syncService: widget.syncService!,
                      repository: widget.repository,
                    ),
                  ),
                );
              },
              child: const Text('View All'),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allowSave = (widget.canSave ?? true) && !widget.readOnly;
    final allowDelete =
        (widget.canDelete ?? (widget.document != null)) &&
        !widget.readOnly &&
        widget.document != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.translate != null
              ? widget.translate!(widget.meta.label ?? widget.meta.name)
              : (widget.meta.label ?? widget.meta.name),
        ),
        actions: [
          if (allowSave)
            TextButton.icon(
              onPressed: _isSaving ? null : () => _triggerSubmit?.call(),
              icon: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text('Save'),
            ),
          if (allowDelete)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _isSaving ? null : _handleDelete,
              tooltip: 'Delete',
            ),
        ],
      ),
      body: Column(
        children: [
          if (_errorMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red[50],
              child: Row(
                children: [
                  const Icon(Icons.error, color: Colors.red),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: FrappeFormBuilder(
              key: widget.document != null
                  ? ValueKey('form_${widget.document!.localId}')
                  : const ValueKey('form_new'),
              meta: widget.meta,
              initialData: widget.document?.data,
              onSubmit: _handleSubmit,
              readOnly: _isSaving || widget.readOnly,
              linkOptionService: widget.linkOptionService,
              uploadFile: widget.api != null
                  ? (file) async {
                      final res = await widget.api!.attachment.uploadFile(file);
                      return res['file_url'] as String? ??
                          res['file_name'] as String?;
                    }
                  : null,
              fileUrlBase: widget.api?.baseUrl,
              imageHeaders: widget.api?.requestHeaders,
              fetchLinkedDocument: _fetchLinkedDocument,
              getMeta: widget.metaService != null
                  ? (doctype) => widget.metaService!.getMeta(doctype)
                  : null,
              registerSubmit: (trigger) => _triggerSubmit = trigger,
              style: widget.style,
              translate: widget.translate,
            ),
          ),
        ],
      ),
    );
  }
}
