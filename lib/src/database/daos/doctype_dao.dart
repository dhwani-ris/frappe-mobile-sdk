import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class DoctypeDao {
  final DatabaseExecutor _db;
  final String _table;

  DoctypeDao(this._db, {required String tableName}) : _table = tableName;

  Future<void> insert(Map<String, Object?> row) async {
    row.putIfAbsent('mobile_uuid', () => const Uuid().v4());
    row.putIfAbsent(
      'local_modified',
      () => DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    await _db.insert(_table, row, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<Map<String, Object?>?> findByMobileUuid(String uuid) async {
    final rows = await _db.query(
      _table,
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  Future<Map<String, Object?>?> findByServerName(String name) async {
    final rows = await _db.query(
      _table,
      where: 'server_name = ?',
      whereArgs: [name],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  Future<List<Map<String, Object?>>> findByStatus(String status) async {
    final rows = await _db.query(
      _table,
      where: 'sync_status = ?',
      whereArgs: [status],
    );
    return rows.map(Map<String, Object?>.from).toList();
  }

  Future<int> updateByMobileUuid(
    String uuid,
    Map<String, Object?> patch,
  ) async {
    return _db.update(
      _table,
      patch,
      where: 'mobile_uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// Upsert a server-originated row by server_name. Preserves mobile_uuid
  /// if the row already exists; generates one otherwise.
  Future<void> upsertByServerName(
    String serverName,
    Map<String, Object?> fields,
  ) async {
    final existing = await _db.query(
      _table,
      columns: ['mobile_uuid'],
      where: 'server_name = ?',
      whereArgs: [serverName],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      await _db.update(
        _table,
        fields,
        where: 'server_name = ?',
        whereArgs: [serverName],
      );
    } else {
      final row = Map<String, Object?>.from(fields);
      row['server_name'] = serverName;
      row.putIfAbsent('mobile_uuid', () => const Uuid().v4());
      row.putIfAbsent(
        'local_modified',
        () => DateTime.now().toUtc().millisecondsSinceEpoch,
      );
      await _db.insert(_table, row);
    }
  }

  Future<int> deleteByMobileUuid(String uuid) async {
    return _db.delete(_table, where: 'mobile_uuid = ?', whereArgs: [uuid]);
  }
}
