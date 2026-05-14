import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class DoctypeDao {
  final DatabaseExecutor _db;
  final String _table;

  DoctypeDao(this._db, {required String tableName}) : _table = tableName;

  /// Stamps a new (or upsert-new) row with `mobile_uuid` and
  /// `local_modified` if the caller didn't already provide them.
  /// Shared by [insert] and the insert branch of [upsertByServerName]
  /// so identity stamping cannot diverge between the two write paths.
  void _stamp(Map<String, Object?> row) {
    row.putIfAbsent('mobile_uuid', () => const Uuid().v4());
    row.putIfAbsent(
      'local_modified',
      () => DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// Returns the first matching row or null. Used by [findByMobileUuid]
  /// and [findByServerName] — keeps the query shape (limit, copy-out)
  /// in a single place.
  Future<Map<String, Object?>?> _findOneWhere(String col, Object value) async {
    final rows = await _db.query(
      _table,
      where: '$col = ?',
      whereArgs: [value],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.first);
  }

  Future<void> insert(Map<String, Object?> row) async {
    _stamp(row);
    await _db.insert(_table, row, conflictAlgorithm: ConflictAlgorithm.abort);
  }

  Future<Map<String, Object?>?> findByMobileUuid(String uuid) =>
      _findOneWhere('mobile_uuid', uuid);

  Future<Map<String, Object?>?> findByServerName(String name) =>
      _findOneWhere('server_name', name);

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
      _stamp(row);
      await _db.insert(_table, row);
    }
  }

  Future<int> deleteByMobileUuid(String uuid) async {
    return _db.delete(_table, where: 'mobile_uuid = ?', whereArgs: [uuid]);
  }
}
