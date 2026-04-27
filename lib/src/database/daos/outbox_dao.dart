import 'package:sqflite/sqflite.dart';
import '../../models/outbox_row.dart';

class OutboxDao {
  final DatabaseExecutor _db;

  OutboxDao(this._db);

  Future<int> insertPending({
    required String doctype,
    required String mobileUuid,
    String? serverName,
    required OutboxOperation operation,
    String? payload,
    DateTime? createdAt,
  }) async {
    final ts = (createdAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    return _db.insert('outbox', <String, Object?>{
      'doctype': doctype,
      'mobile_uuid': mobileUuid,
      'server_name': serverName,
      'operation': operation.wireName,
      'payload': payload,
      'state': OutboxState.pending.wireName,
      'retry_count': 0,
      'created_at': ts,
    });
  }

  /// For INSERT/UPDATE: if a row already exists for (doctype,mobileUuid)
  /// in pending|blocked|failed with the same operation, replace payload + reset
  /// to pending in place. Otherwise inserts a new pending row.
  /// SUBMIT/CANCEL/DELETE never collapse.
  Future<int> collapseOrInsert({
    required String doctype,
    required String mobileUuid,
    String? serverName,
    required OutboxOperation operation,
    String? payload,
    DateTime? createdAt,
  }) async {
    final collapsable = operation == OutboxOperation.insert ||
        operation == OutboxOperation.update;
    if (collapsable) {
      final existing = await _db.query(
        'outbox',
        where:
            'doctype = ? AND mobile_uuid = ? AND operation = ? AND state IN (?, ?, ?)',
        whereArgs: [
          doctype,
          mobileUuid,
          operation.wireName,
          OutboxState.pending.wireName,
          OutboxState.blocked.wireName,
          OutboxState.failed.wireName,
        ],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as int;
        await _db.update(
          'outbox',
          <String, Object?>{
            'payload': payload,
            'state': OutboxState.pending.wireName,
            'error_code': null,
            'error_message': null,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
        return id;
      }
    }
    return insertPending(
      doctype: doctype,
      mobileUuid: mobileUuid,
      serverName: serverName,
      operation: operation,
      payload: payload,
      createdAt: createdAt,
    );
  }

  Future<OutboxRow?> findById(int id) async {
    final rows = await _db.query(
      'outbox',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return OutboxRow.fromMap(rows.first);
  }

  Future<List<OutboxRow>> findByState(OutboxState state) async {
    final rows = await _db.query(
      'outbox',
      where: 'state = ?',
      whereArgs: [state.wireName],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(OutboxRow.fromMap).toList();
  }

  Future<void> markInFlight(int id) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.inFlight.wireName,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markDone(int id, {required String serverName}) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.done.wireName,
        'server_name': serverName,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
        'error_code': null,
        'error_message': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markFailed(
    int id, {
    required ErrorCode errorCode,
    required String errorMessage,
  }) async {
    await _db.rawUpdate(
      '''
      UPDATE outbox
        SET state = ?,
            error_code = ?,
            error_message = ?,
            retry_count = retry_count + 1,
            last_attempt_at = ?
        WHERE id = ?
      ''',
      [
        OutboxState.failed.wireName,
        errorCode.wireName,
        errorMessage,
        DateTime.now().toUtc().millisecondsSinceEpoch,
        id,
      ],
    );
  }

  Future<void> markConflict(int id, {String? errorMessage}) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.conflict.wireName,
        'error_code': ErrorCode.TIMESTAMP_MISMATCH.wireName,
        'error_message': errorMessage,
        'last_attempt_at': DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markBlocked(int id, {required String reason}) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.blocked.wireName,
        'error_message': reason,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> pruneDone({Duration olderThan = const Duration(hours: 24)}) async {
    final cutoff =
        DateTime.now().toUtc().subtract(olderThan).millisecondsSinceEpoch;
    return _db.delete(
      'outbox',
      where:
          'state = ? AND last_attempt_at IS NOT NULL AND last_attempt_at < ?',
      whereArgs: [OutboxState.done.wireName, cutoff],
    );
  }

  Future<Map<OutboxState, int>> countByState() async {
    final rows = await _db.rawQuery(
      'SELECT state, COUNT(*) AS n FROM outbox GROUP BY state',
    );
    final out = <OutboxState, int>{};
    for (final r in rows) {
      out[OutboxStateHelpers.parse(r['state'] as String)] = r['n'] as int;
    }
    return out;
  }

  Future<int> resetInFlightToPending() async {
    return _db.update(
      'outbox',
      <String, Object?>{'state': OutboxState.pending.wireName},
      where: 'state = ?',
      whereArgs: [OutboxState.inFlight.wireName],
    );
  }

  /// Flips a row in any non-pending state back to `pending` so the push
  /// engine picks it up on the next drain. Clears `error_code` /
  /// `error_message` so retries start with a fresh slate; `retry_count`
  /// is preserved so the UI can surface "retried N times". Used by
  /// `SyncController.retry` / `retryAll` and the conflict-resolution
  /// flow's "keep local + retry" branch.
  Future<void> resetToPending(int id) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.pending.wireName,
        'error_code': null,
        'error_message': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<bool> hasActivePushFor(String doctype) async {
    final rows = await _db.rawQuery(
      '''SELECT 1 FROM outbox
         WHERE doctype = ? AND state IN (?, ?)
         LIMIT 1''',
      [
        doctype,
        OutboxState.pending.wireName,
        OutboxState.inFlight.wireName,
      ],
    );
    return rows.isNotEmpty;
  }
}
