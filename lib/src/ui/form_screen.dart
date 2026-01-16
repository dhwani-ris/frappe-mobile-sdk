import 'package:flutter/material.dart';
import '../models/doc_type_meta.dart';
import '../models/document.dart';
import '../services/offline_repository.dart';
import '../services/sync_service.dart';
import '../services/link_option_service.dart';
import 'widgets/form_builder.dart';
import 'sync_status_screen.dart';

/// Screen for displaying and editing a Frappe document form
class FormScreen extends StatefulWidget {
  final DocTypeMeta meta;
  final Document? document;
  final OfflineRepository repository;
  final SyncService? syncService;
  final LinkOptionService? linkOptionService;
  final Function()? onSaveSuccess;

  const FormScreen({
    super.key,
    required this.meta,
    this.document,
    required this.repository,
    this.syncService,
    this.linkOptionService,
    this.onSaveSuccess,
  });

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  bool _isSaving = false;
  String? _errorMessage;

  Future<void> _handleSubmit(Map<String, dynamic> formData) async {
    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      if (widget.document == null) {
        // Create new document
        await widget.repository.createDocument(
          doctype: widget.meta.name,
          data: formData,
        );
      } else {
        // Update existing document - merge with existing data to preserve all fields
        final existingData = Map<String, dynamic>.from(widget.document!.data);
        existingData.addAll(formData); // formData overwrites existing values
        await widget.repository.updateDocumentData(
          widget.document!.localId,
          existingData,
        );
      }

      // Try to sync if online
      if (widget.syncService != null) {
        final isOnline = await widget.syncService!.isOnline();
        if (isOnline) {
          try {
            // Push sync immediately after save
            print('Pushing sync for doctype: ${widget.meta.name}');
            final syncResult = await widget.syncService!.pushSync(doctype: widget.meta.name);
            print('Sync result: ${syncResult.success} success, ${syncResult.failed} failed, ${syncResult.total} total');
            if (mounted) {
              if (syncResult.errors.isNotEmpty) {
                // Show error dialog with details
                _showSyncErrorDialog(syncResult.errors);
              } else if (syncResult.failed > 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Saved locally. ${syncResult.failed} update(s) failed to sync.'),
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
                    content: Text('Saved and synced successfully (${syncResult.success} document(s))'),
                    backgroundColor: Colors.green,
                  ),
                );
              }
            }
          } catch (e) {
            // Sync failed, but document is saved locally
            print('Sync failed: $e');
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
                        if (widget.syncService != null && widget.repository != null) {
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
        } else {
          // Offline - document is saved locally and will sync when online
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Saved locally. Will sync when online.'),
                backgroundColor: Colors.blue,
                duration: Duration(seconds: 2),
              ),
            );
          }
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
        _errorMessage = e.toString();
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
      // Delete the document (marks as deleted)
      await widget.repository.deleteDocument(widget.document!.localId);

      // Try to sync if online
      if (widget.syncService != null) {
        final isOnline = await widget.syncService!.isOnline();
        if (isOnline) {
          try {
            // Push the deletion to server
            await widget.syncService!.pushSync(doctype: widget.meta.name);
          } catch (e) {
            print('Sync failed: $e');
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
        // Navigate back and refresh list
        Navigator.pop(context);
        widget.onSaveSuccess?.call();
      }
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
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
          if (widget.syncService != null && widget.repository != null)
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
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.meta.label ?? widget.meta.name),
        actions: [
          if (widget.document != null)
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
              readOnly: _isSaving,
              linkOptionService: widget.linkOptionService,
            ),
          ),
        ],
      ),
    );
  }
}
