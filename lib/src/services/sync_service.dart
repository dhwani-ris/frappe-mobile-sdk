import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../api/client.dart';
import '../database/app_database.dart';
import '../models/doc_type_meta.dart';
import 'offline_repository.dart';

/// Service for bi-directional sync
class SyncService {
  final FrappeClient _client;
  final OfflineRepository _repository;
  final AppDatabase _database; // ignore: unused_field
  final Future<String?> Function()? _getMobileUuid;
  bool _isSyncing = false;

  SyncService(
    this._client,
    this._repository,
    this._database, {
    Future<String?> Function()? getMobileUuid,
  }) : _getMobileUuid = getMobileUuid;

  /// Check if device is online
  Future<bool> isOnline() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    return connectivityResult.contains(ConnectivityResult.mobile) ||
        connectivityResult.contains(ConnectivityResult.wifi) ||
        connectivityResult.contains(ConnectivityResult.ethernet);
  }

  /// Sync all dirty documents (push)
  Future<SyncResult> pushSync({String? doctype}) async {
    if (_isSyncing) {
      return SyncResult(0, 0, 0, 'Sync already in progress', errors: []);
    }

    if (!await isOnline()) {
      return SyncResult(0, 0, 0, 'No internet connection', errors: []);
    }

    _isSyncing = true;
    int success = 0;
    int failed = 0;
    int total = 0;
    final List<SyncError> errors = [];

    try {
      final dirtyDocs = doctype != null
          ? await _repository.getDirtyDocumentsByDoctype(doctype)
          : await _repository.getDirtyDocuments();

      total = dirtyDocs.length;

      for (final doc in dirtyDocs) {
        try {
          if (doc.status == 'deleted') {
            if (doc.serverId != null) {
              try {
                await _client.document.deleteDocument(
                  doc.doctype,
                  doc.serverId!,
                );
              } catch (e) {
                rethrow;
              }
            }
            await _repository.hardDeleteDocument(doc.localId);
            success++;
          } else if (doc.serverId == null) {
            try {
              final data = Map<String, dynamic>.from(doc.data);
              if (_getMobileUuid != null) {
                final uuid = await _getMobileUuid();
                if (uuid != null && uuid.isNotEmpty) {
                  data['mobile_uuid'] = uuid;
                }
              }
              final result = await _client.document.createDocument(
                doc.doctype,
                data,
              );

              final serverId =
                  result['name'] as String? ?? result['docname'] as String?;
              if (serverId != null) {
                final updated = doc.copyWith(
                  serverId: serverId,
                  status: 'clean',
                  modified: DateTime.now().millisecondsSinceEpoch,
                );
                await _repository.updateDocument(updated);
              }
            } catch (e) {
              rethrow;
            }
            success++;
          } else {
            try {
              await _client.document.updateDocument(
                doc.doctype,
                doc.serverId!,
                doc.data,
              );
            } catch (e) {
              rethrow;
            }

            final updated = doc.markClean();
            await _repository.updateDocument(updated);
            success++;
          }
        } catch (e) {
          final errorMsg = e.toString();
          failed++;

          // Track error details
          final operation = doc.status == 'deleted'
              ? 'delete'
              : (doc.serverId == null ? 'create' : 'update');
          errors.add(
            SyncError(
              documentId: doc.serverId ?? doc.localId,
              doctype: doc.doctype,
              operation: operation,
              errorMessage: errorMsg,
            ),
          );
        }
      }

      return SyncResult(success, failed, total, null, errors: errors);
    } finally {
      _isSyncing = false;
    }
  }

  /// Pull updates from server
  Future<SyncResult> pullSync({required String doctype, int? since}) async {
    if (_isSyncing) {
      return SyncResult(0, 0, 0, 'Sync already in progress', errors: []);
    }

    if (!await isOnline()) {
      return SyncResult(0, 0, 0, 'No internet connection', errors: []);
    }

    _isSyncing = true;
    int success = 0;
    int failed = 0;
    int total = 0;
    final List<SyncError> errors = [];

    try {
      List<List<dynamic>>? filters;
      if (since != null) {
        final sinceDate = DateTime.fromMillisecondsSinceEpoch(since);
        filters = [
          ['modified', '>', sinceDate.toIso8601String()],
        ];
      }

      // If the parent meta declares any `Table` / `Table MultiSelect`
      // field, the bare `frappe.client.get_list` response is missing
      // child arrays — we need full docs (`/api/resource/<doctype>/<name>`).
      // Otherwise the cheaper flat `get_list` is fine. We resolve the
      // meta from cache (or doctype_meta DAO) so this works for
      // returning users where `ensureSchemaForClosure` ran on a previous
      // launch only.
      final needsFullDoc =
          _repository.doctypesWithChildren().contains(doctype) ||
              await _doctypeHasChildTables(doctype);

      // Paginate via `limit_start` until the server returns a short page
      // (fewer rows than requested). Without this, doctypes with > 1000
      // rows (Village, Hamlet, etc.) silently truncate at the first page.
      // Page size is the API cap, not a UX choice.
      const int pageSize = 1000;
      int start = 0;
      while (true) {
        final List<dynamic> page = needsFullDoc
            ? await _client.doctype.listFullDocs(
                doctype,
                filters: filters,
                limitStart: start,
                limitPageLength: pageSize,
              )
            : await _client.doctype.list(
                doctype,
                filters: filters,
                fields: ['*'],
                limitStart: start,
                limitPageLength: pageSize,
              );
        if (page.isEmpty) break;
        total += page.length;

        for (final docData in page) {
          try {
            final serverId = docData['name'] as String? ??
                docData['docname'] as String?;
            if (serverId == null) continue;
            await _repository.saveServerDocument(
              doctype: doctype,
              serverId: serverId,
              data: docData as Map<String, dynamic>,
            );
            success++;
          } catch (e) {
            failed++;
            final docId = docData['name'] as String? ??
                docData['docname'] as String? ??
                'unknown';
            errors.add(SyncError(
              documentId: docId,
              doctype: doctype,
              operation: 'pull',
              errorMessage: e.toString(),
            ));
          }
        }

        // Last page: server returned fewer than we asked for. Empty next
        // pages are also handled by the top-of-loop `isEmpty` guard.
        if (page.length < pageSize) break;
        start += page.length;
      }

      return SyncResult(success, failed, total, null, errors: errors);
    } finally {
      _isSyncing = false;
    }
  }

  Future<bool> _doctypeHasChildTables(String doctype) async {
    final raw = await _database.doctypeMetaDao.getMetaJson(doctype);
    if (raw == null || raw.isEmpty || raw == '{}') return false;
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final meta = DocTypeMeta.fromJson(parsed);
      for (final f in meta.fields) {
        if (f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Full sync (push + pull) for a DocType
  Future<SyncResult> syncDoctype(String doctype) async {
    if (_isSyncing) {
      return SyncResult(0, 0, 0, 'Sync already in progress', errors: []);
    }

    if (!await isOnline()) {
      return SyncResult(0, 0, 0, 'No internet connection', errors: []);
    }

    _isSyncing = true;

    try {
      final pushResult = await pushSync(doctype: doctype);

      final localDocs = await _repository.getDocumentsByDoctype(doctype);
      int? lastModified;
      if (localDocs.isNotEmpty) {
        lastModified = localDocs
            .map((d) => d.modified)
            .reduce((a, b) => a > b ? a : b);
      }

      final pullResult = await pullSync(doctype: doctype, since: lastModified);

      final allErrors = <SyncError>[];
      allErrors.addAll(pushResult.errors);
      allErrors.addAll(pullResult.errors);

      return SyncResult(
        pushResult.success + pullResult.success,
        pushResult.failed + pullResult.failed,
        pushResult.total + pullResult.total,
        null,
        errors: allErrors,
      );
    } finally {
      _isSyncing = false;
    }
  }

  /// Get sync statistics
  Future<Map<String, int>> getSyncStats({String? doctype}) async {
    final dirtyDocs = doctype != null
        ? await _repository.getDirtyDocumentsByDoctype(doctype)
        : await _repository.getDirtyDocuments();

    final deletedCount = dirtyDocs.where((d) => d.status == 'deleted').length;
    final dirtyCount = dirtyDocs.where((d) => d.status == 'dirty').length;

    return {
      'dirty': dirtyCount,
      'deleted': deletedCount,
      'total': dirtyDocs.length,
    };
  }
}

/// Result of sync operation
class SyncResult {
  final int success;
  final int failed;
  final int total;
  final String? error;
  final List<SyncError> errors;

  SyncResult(
    this.success,
    this.failed,
    this.total,
    this.error, {
    List<SyncError>? errors,
  }) : errors = errors ?? [];
}

/// Individual sync error details
class SyncError {
  final String documentId;
  final String doctype;
  final String operation;
  final String errorMessage;
  final DateTime timestamp;

  SyncError({
    required this.documentId,
    required this.doctype,
    required this.operation,
    required this.errorMessage,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  @override
  String toString() {
    return '$operation failed for $doctype/$documentId: $errorMessage';
  }
}
