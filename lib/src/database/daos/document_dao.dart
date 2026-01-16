import 'package:floor/floor.dart';
import '../entities/document_entity.dart';

@dao
abstract class DocumentDao {
  @Query('SELECT * FROM documents WHERE localId = :localId')
  Future<DocumentEntity?> findByLocalId(String localId);

  @Query('SELECT * FROM documents WHERE serverId = :serverId AND doctype = :doctype')
  Future<DocumentEntity?> findByServerId(String serverId, String doctype);

  @Query('SELECT * FROM documents WHERE doctype = :doctype ORDER BY modified DESC')
  Future<List<DocumentEntity>> findByDoctype(String doctype);

  @Query('SELECT * FROM documents WHERE doctype = :doctype AND status = :status ORDER BY modified DESC')
  Future<List<DocumentEntity>> findByDoctypeAndStatus(String doctype, String status);

  @Query('SELECT * FROM documents WHERE status = :status ORDER BY modified ASC')
  Future<List<DocumentEntity>> findByStatus(String status);

  @Query('SELECT * FROM documents WHERE doctype = :doctype AND modified > :since ORDER BY modified DESC')
  Future<List<DocumentEntity>> findByDoctypeSince(String doctype, int since);

  @Query('SELECT * FROM documents WHERE doctype IN (:doctypes) ORDER BY modified DESC')
  Future<List<DocumentEntity>> findByDoctypes(List<String> doctypes);

  @Query('SELECT * FROM documents ORDER BY modified DESC')
  Future<List<DocumentEntity>> findAll();

  @insert
  Future<void> insertDocument(DocumentEntity document);

  @insert
  Future<void> insertDocuments(List<DocumentEntity> documents);

  @update
  Future<void> updateDocument(DocumentEntity document);

  @update
  Future<void> updateDocuments(List<DocumentEntity> documents);

  @delete
  Future<void> deleteDocument(DocumentEntity document);

  @Query('DELETE FROM documents WHERE localId = :localId')
  Future<void> deleteByLocalId(String localId);

  @Query('DELETE FROM documents WHERE doctype = :doctype')
  Future<void> deleteByDoctype(String doctype);

  @Query('DELETE FROM documents WHERE doctype = :doctype AND status = :status')
  Future<void> deleteByDoctypeAndStatus(String doctype, String status);

  @Query('DELETE FROM documents')
  Future<void> deleteAll();
}
