import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../models/document.dart';
import '../database/app_database.dart';
import '../database/entities/document_entity.dart';

/// Repository for offline document operations
class OfflineRepository {
  final AppDatabase _database;
  final Uuid _uuid = const Uuid();

  OfflineRepository(this._database);

  /// Create a new document locally
  Future<Document> createDocument({
    required String doctype,
    required Map<String, dynamic> data,
  }) async {
    final localId = _uuid.v4();
    final document = Document.create(
      doctype: doctype,
      data: data,
      localId: localId,
    );

    final entity = _documentToEntity(document);
    await _database.documentDao.insertDocument(entity);

    return document;
  }

  /// Get document by local ID
  Future<Document?> getDocumentByLocalId(String localId) async {
    final entity = await _database.documentDao.findByLocalId(localId);
    return entity != null ? _entityToDocument(entity) : null;
  }

  /// Get document by server ID
  Future<Document?> getDocumentByServerId(
    String serverId,
    String doctype,
  ) async {
    final entity = await _database.documentDao.findByServerId(
      serverId,
      doctype,
    );
    return entity != null ? _entityToDocument(entity) : null;
  }

  /// Get all documents for a DocType (excluding deleted)
  Future<List<Document>> getDocumentsByDoctype(String doctype) async {
    final entities = await _database.documentDao.findByDoctype(doctype);
    final documents = entities.map(_entityToDocument).toList();
    // Filter out deleted documents
    return documents.where((doc) => doc.status != 'deleted').toList();
  }

  /// Get documents by status
  Future<List<Document>> getDocumentsByStatus(String status) async {
    final entities = await _database.documentDao.findByStatus(status);
    return entities.map(_entityToDocument).toList();
  }

  /// Get dirty documents (need sync)
  Future<List<Document>> getDirtyDocuments() async {
    return await getDocumentsByStatus('dirty');
  }

  /// Get dirty documents for a specific DocType
  Future<List<Document>> getDirtyDocumentsByDoctype(String doctype) async {
    final entities = await _database.documentDao.findByDoctypeAndStatus(
      doctype,
      'dirty',
    );
    return entities.map(_entityToDocument).toList();
  }

  /// Update document
  Future<Document> updateDocument(Document document) async {
    final entity = _documentToEntity(document);
    await _database.documentDao.updateDocument(entity);
    return document;
  }

  /// Update document data
  Future<Document> updateDocumentData(
    String localId,
    Map<String, dynamic> data,
  ) async {
    final document = await getDocumentByLocalId(localId);
    if (document == null) {
      throw Exception('Document not found: $localId');
    }

    final updated = document.updateData(data);
    await updateDocument(updated);
    return updated;
  }

  /// Delete document (soft delete - marks as deleted)
  Future<Document> deleteDocument(String localId) async {
    final document = await getDocumentByLocalId(localId);
    if (document == null) {
      throw Exception('Document not found: $localId');
    }

    final deleted = document.markDeleted();
    await updateDocument(deleted);
    return deleted;
  }

  /// Hard delete document (permanently remove from database)
  Future<void> hardDeleteDocument(String localId) async {
    await _database.documentDao.deleteByLocalId(localId);
  }

  /// Save server document locally
  Future<Document> saveServerDocument({
    required String doctype,
    required String serverId,
    required Map<String, dynamic> data,
  }) async {
    // Check if already exists
    final existing = await getDocumentByServerId(serverId, doctype);
    if (existing != null) {
      // Update existing
      final updated = existing.copyWith(
        serverId: serverId,
        data: data,
        status: 'clean',
        modified: DateTime.now().millisecondsSinceEpoch,
      );
      await updateDocument(updated);
      return updated;
    }

    // Create new
    final localId = _uuid.v4();
    final document = Document.fromServer(
      doctype: doctype,
      serverId: serverId,
      data: data,
      localId: localId,
    );

    final entity = _documentToEntity(document);
    await _database.documentDao.insertDocument(entity);

    return document;
  }

  /// Convert Document to Entity
  DocumentEntity _documentToEntity(Document document) {
    return DocumentEntity(
      localId: document.localId,
      doctype: document.doctype,
      serverId: document.serverId,
      dataJson: jsonEncode(document.data),
      status: document.status,
      modified: document.modified,
    );
  }

  /// Convert Entity to Document
  Document _entityToDocument(DocumentEntity entity) {
    return Document(
      localId: entity.localId,
      doctype: entity.doctype,
      serverId: entity.serverId,
      data: jsonDecode(entity.dataJson) as Map<String, dynamic>,
      status: entity.status,
      modified: entity.modified,
    );
  }
}
