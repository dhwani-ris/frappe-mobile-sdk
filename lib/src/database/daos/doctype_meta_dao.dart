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

  // ────────── v2 offline-first extensions (additive) ──────────

  Future<void> setTableName(String doctype, String tableName) async {
    await _database.update(
      'doctype_meta',
      <String, Object?>{'table_name': tableName},
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<String?> getTableName(String doctype) async {
    final rows = await _database.query(
      'doctype_meta',
      columns: ['table_name'],
      where: 'doctype = ?',
      whereArgs: [doctype],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['table_name'] as String?;
  }

  Future<void> setMetaWatermark(String doctype, String watermark) async {
    await _database.update(
      'doctype_meta',
      <String, Object?>{'meta_watermark': watermark},
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<String?> getMetaWatermark(String doctype) async {
    final rows = await _database.query(
      'doctype_meta',
      columns: ['meta_watermark'],
      where: 'doctype = ?',
      whereArgs: [doctype],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['meta_watermark'] as String?;
  }

  Future<void> setDepGraphJson(String doctype, String depGraphJson) async {
    await _database.update(
      'doctype_meta',
      <String, Object?>{'dep_graph_json': depGraphJson},
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<String?> getDepGraphJson(String doctype) async {
    final rows = await _database.query(
      'doctype_meta',
      columns: ['dep_graph_json'],
      where: 'doctype = ?',
      whereArgs: [doctype],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['dep_graph_json'] as String?;
  }

  Future<void> setLastOkCursor(String doctype, String cursorJson) async {
    await _database.update(
      'doctype_meta',
      <String, Object?>{
        'last_ok_cursor': cursorJson,
        'last_pull_ok_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<String?> getLastOkCursor(String doctype) async {
    final rows = await _database.query(
      'doctype_meta',
      columns: ['last_ok_cursor'],
      where: 'doctype = ?',
      whereArgs: [doctype],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['last_ok_cursor'] as String?;
  }

  Future<void> markEntryPoint(String doctype, bool isEntryPoint) async {
    await _database.update(
      'doctype_meta',
      <String, Object?>{'is_entry_point': isEntryPoint ? 1 : 0},
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  Future<void> markChildTable(String doctype, bool isChildTable) async {
    await _database.update(
      'doctype_meta',
      <String, Object?>{'is_child_table': isChildTable ? 1 : 0},
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
  }

  /// Lighter accessors for offline-first meta sync — avoid round-tripping
  /// through [DoctypeMetaEntity] when only the JSON blob is needed.
  Future<String?> getMetaJson(String doctype) async {
    final rows = await _database.query(
      'doctype_meta',
      columns: ['metaJson'],
      where: 'doctype = ?',
      whereArgs: [doctype],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['metaJson'] as String?;
  }

  Future<void> upsertMetaJson(String doctype, String metaJson) async {
    final updated = await _database.update(
      'doctype_meta',
      <String, Object?>{'metaJson': metaJson},
      where: 'doctype = ?',
      whereArgs: [doctype],
    );
    if (updated == 0) {
      await _database.insert('doctype_meta', <String, Object?>{
        'doctype': doctype,
        'metaJson': metaJson,
        'isMobileForm': 0,
      });
    }
  }
}
