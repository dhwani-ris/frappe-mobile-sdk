import 'package:sqflite/sqflite.dart';
import '../entities/document_entity.dart';

class DocumentDao {
  final Database _database;

  DocumentDao(this._database);

  Future<DocumentEntity?> findByLocalId(String localId) async {
    final maps = await _database.query(
      'documents',
      where: 'localId = ?',
      whereArgs: [localId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DocumentEntity.fromDb(maps.first);
  }

  Future<DocumentEntity?> findByServerId(
    String serverId,
    String doctype,
  ) async {
    final maps = await _database.query(
      'documents',
      where: 'serverId = ? AND doctype = ?',
      whereArgs: [serverId, doctype],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DocumentEntity.fromDb(maps.first);
  }

  Future<List<DocumentEntity>> findByDoctype(String doctype) async {
    final maps = await _database.query(
      'documents',
      where: 'doctype = ?',
      whereArgs: [doctype],
      orderBy: 'modified DESC',
    );
    return maps.map((map) => DocumentEntity.fromDb(map)).toList();
  }

  Future<List<DocumentEntity>> findByDoctypeAndStatus(
    String doctype,
    String status,
  ) async {
    final maps = await _database.query(
      'documents',
      where: 'doctype = ? AND status = ?',
      whereArgs: [doctype, status],
      orderBy: 'modified DESC',
    );
    return maps.map((map) => DocumentEntity.fromDb(map)).toList();
  }

  Future<List<DocumentEntity>> findByStatus(String status) async {
    final maps = await _database.query(
      'documents',
      where: 'status = ?',
      whereArgs: [status],
      orderBy: 'modified ASC',
    );
    return maps.map((map) => DocumentEntity.fromDb(map)).toList();
  }

  Future<List<DocumentEntity>> findByDoctypeSince(
    String doctype,
    int since,
  ) async {
    final maps = await _database.query(
      'documents',
      where: 'doctype = ? AND modified > ?',
      whereArgs: [doctype, since],
      orderBy: 'modified DESC',
    );
    return maps.map((map) => DocumentEntity.fromDb(map)).toList();
  }

  Future<List<DocumentEntity>> findByDoctypes(List<String> doctypes) async {
    if (doctypes.isEmpty) return [];
    final placeholders = List.filled(doctypes.length, '?').join(',');
    final maps = await _database.query(
      'documents',
      where: 'doctype IN ($placeholders)',
      whereArgs: doctypes,
      orderBy: 'modified DESC',
    );
    return maps.map((map) => DocumentEntity.fromDb(map)).toList();
  }

  Future<List<DocumentEntity>> findAll() async {
    final maps = await _database.query('documents', orderBy: 'modified DESC');
    return maps.map((map) => DocumentEntity.fromDb(map)).toList();
  }

  Future<void> insertDocument(DocumentEntity document) async {
    await _database.insert(
      'documents',
      document.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertDocuments(List<DocumentEntity> documents) async {
    if (documents.isEmpty) return;
    final batch = _database.batch();
    for (final document in documents) {
      batch.insert(
        'documents',
        document.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateDocument(DocumentEntity document) async {
    await _database.update(
      'documents',
      document.toDb(),
      where: 'localId = ?',
      whereArgs: [document.localId],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateDocuments(List<DocumentEntity> documents) async {
    if (documents.isEmpty) return;
    final batch = _database.batch();
    for (final document in documents) {
      batch.update(
        'documents',
        document.toDb(),
        where: 'localId = ?',
        whereArgs: [document.localId],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> deleteDocument(DocumentEntity document) async {
    await deleteByLocalId(document.localId);
  }

  Future<void> deleteByLocalId(String localId) async {
    await _database.delete(
      'documents',
      where: 'localId = ?',
      whereArgs: [localId],
    );
  }

  Future<void> deleteByDoctype(String doctype) async {
    await _database.delete(
      'documents',
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<void> deleteByDoctypeAndStatus(String doctype, String status) async {
    await _database.delete(
      'documents',
      where: 'doctype = ? AND status = ?',
      whereArgs: [doctype, status],
    );
  }

  Future<void> deleteAll() async {
    await _database.delete('documents');
  }
}
