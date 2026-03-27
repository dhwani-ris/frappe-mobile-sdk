import 'package:sqflite/sqflite.dart';
import '../entities/doctype_meta_entity.dart';

class DoctypeMetaDao {
  final Database _database;

  DoctypeMetaDao(this._database);

  Future<DoctypeMetaEntity?> findByDoctype(String doctype) async {
    final maps = await _database.query(
      'doctype_meta',
      where: 'doctype = ?',
      whereArgs: [doctype],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return DoctypeMetaEntity.fromDb(maps.first);
  }

  Future<List<DoctypeMetaEntity>> findAll() async {
    final maps = await _database.query('doctype_meta');
    return maps.map((map) => DoctypeMetaEntity.fromDb(map)).toList();
  }

  Future<List<DoctypeMetaEntity>> findByDoctypes(List<String> doctypes) async {
    if (doctypes.isEmpty) return [];
    final placeholders = List.filled(doctypes.length, '?').join(',');
    final maps = await _database.query(
      'doctype_meta',
      where: 'doctype IN ($placeholders)',
      whereArgs: doctypes,
    );
    return maps.map((map) => DoctypeMetaEntity.fromDb(map)).toList();
  }

  Future<List<DoctypeMetaEntity>> findMobileFormDoctypes() async {
    final maps = await _database.query(
      'doctype_meta',
      where: 'isMobileForm = ?',
      whereArgs: [1],
      orderBy: 'sortOrder ASC',
    );
    return maps.map((map) => DoctypeMetaEntity.fromDb(map)).toList();
  }

  Future<void> insertDoctypeMeta(DoctypeMetaEntity meta) async {
    await _database.insert(
      'doctype_meta',
      meta.toDb(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertDoctypeMetas(List<DoctypeMetaEntity> metas) async {
    if (metas.isEmpty) return;
    final batch = _database.batch();
    for (final meta in metas) {
      batch.insert(
        'doctype_meta',
        meta.toDb(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateDoctypeMeta(DoctypeMetaEntity meta) async {
    await _database.update(
      'doctype_meta',
      meta.toDb(),
      where: 'doctype = ?',
      whereArgs: [meta.doctype],
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteDoctypeMeta(DoctypeMetaEntity meta) async {
    await deleteByDoctype(meta.doctype);
  }

  Future<void> deleteByDoctype(String doctype) async {
    await _database.delete(
      'doctype_meta',
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<void> deleteAll() async {
    await _database.delete('doctype_meta');
  }
}
