import 'package:floor/floor.dart';
import '../entities/doctype_meta_entity.dart';

@dao
abstract class DoctypeMetaDao {
  @Query('SELECT * FROM doctype_meta WHERE doctype = :doctype')
  Future<DoctypeMetaEntity?> findByDoctype(String doctype);

  @Query('SELECT * FROM doctype_meta')
  Future<List<DoctypeMetaEntity>> findAll();

  @Query('SELECT * FROM doctype_meta WHERE doctype IN (:doctypes)')
  Future<List<DoctypeMetaEntity>> findByDoctypes(List<String> doctypes);

  @Query('SELECT * FROM doctype_meta WHERE isMobileForm = 1')
  Future<List<DoctypeMetaEntity>> findMobileFormDoctypes();

  @insert
  Future<void> insertDoctypeMeta(DoctypeMetaEntity meta);

  @insert
  Future<void> insertDoctypeMetas(List<DoctypeMetaEntity> metas);

  @update
  Future<void> updateDoctypeMeta(DoctypeMetaEntity meta);

  @delete
  Future<void> deleteDoctypeMeta(DoctypeMetaEntity meta);

  @Query('DELETE FROM doctype_meta WHERE doctype = :doctype')
  Future<void> deleteByDoctype(String doctype);

  @Query('DELETE FROM doctype_meta')
  Future<void> deleteAll();
}
