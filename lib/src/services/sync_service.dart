import 'package:connectivity_plus/connectivity_plus.dart';
import '../api/client.dart';
import '../database/app_database.dart';
import 'offline_repository.dart';

/// Service for bi-directional sync
class SyncService {
  final FrappeClient _client;
  final OfflineRepository _repository;
  final AppDatabase _database; // ignore: unused_field
  bool _isSyncing = false;

  SyncService(this._client, this._repository, this._database);

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
              final result = await _client.document.createDocument(
                doc.doctype,
                doc.data,
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

      final result = await _client.doctype.list(
        doctype,
        filters: filters,
        fields: ['*'],
        limitPageLength: 1000,
      );

      total = result.length;

      for (final docData in result) {
        try {
          final serverId =
              docData['name'] as String? ?? docData['docname'] as String?;
          if (serverId == null) continue;

          await _repository.saveServerDocument(
            doctype: doctype,
            serverId: serverId,
            data: docData as Map<String, dynamic>,
          );
          success++;
        } catch (e) {
          final errorMsg = e.toString();
          failed++;

          final docId =
              docData['name'] as String? ??
              docData['docname'] as String? ??
              'unknown';
          errors.add(
            SyncError(
              documentId: docId,
              doctype: doctype,
              operation: 'pull',
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
