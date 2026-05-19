import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class ChildDao {
  final DatabaseExecutor _db;
  final String _table;

  ChildDao(this._db, {required String tableName}) : _table = tableName;

  Future<void> insert(Map<String, Object?> row) async {
    row.putIfAbsent('mobile_uuid', () => const Uuid().v4());
    await _db.insert(_table, row, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<List<Map<String, Object?>>> listByParent(
    String parentUuid,
    String parentfield,
  ) async {
    final rows = await _db.query(
      _table,
      where: 'parent_uuid = ? AND parentfield = ?',
      whereArgs: [parentUuid, parentfield],
      orderBy: 'idx ASC',
    );
    return rows.map(Map<String, Object?>.from).toList();
  }

  Future<int> deleteByParent(String parentUuid, String parentfield) async {
    return _db.delete(
      _table,
      where: 'parent_uuid = ? AND parentfield = ?',
      whereArgs: [parentUuid, parentfield],
    );
  }

  Future<int> deleteAllByParent(String parentUuid) async {
    return _db.delete(_table, where: 'parent_uuid = ?', whereArgs: [parentUuid]);
  }
}
