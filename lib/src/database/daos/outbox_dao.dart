import 'package:sqflite/sqflite.dart';
import '../../models/outbox_row.dart';

/// Outcome of [OutboxDao.recordSave]. Lets the caller decide whether the
/// docs__ row should be tombstoned (`enqueued`) or hard-deleted
/// (`cancelledLocally` — the cancelled INSERT means the server never
/// knew about the doc, so there is nothing to push).
enum RecordSaveResult { enqueued, cancelledLocally }

class OutboxDao {
  final DatabaseExecutor _db;

  OutboxDao(this._db);

  /// Inserts a fresh pending outbox row. Used by tests, by L3 retry seam,
  /// and indirectly by [recordSave] when no collapse target exists.
  Future<int> insertPending({
    required String doctype,
    required String mobileUuid,
    required OutboxOperation operation,
    DateTime? createdAt,
  }) async {
    final ts = (createdAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    return _db.insert('outbox', <String, Object?>{
      'doctype': doctype,
      'mobile_uuid': mobileUuid,
      'operation': operation.wireName,
      'state': OutboxState.pending.wireName,
      'created_at': ts,
    });
  }

  /// Records a save against the outbox per the collapse matrix in
  /// `docs/superpowers/specs/2026-05-07-legacy-documents-retirement-design.md`.
  ///
  /// Only collapses against rows in `pending`, `failed`, `blocked`,
  /// `conflict` (the "collapsable" buckets). `in_flight` and `done` are
  /// never touched — a save during an in-flight push always inserts a
  /// fresh follow-up row.
  Future<RecordSaveResult> recordSave({
    required String doctype,
    required String mobileUuid,
    required OutboxOperation operation,
    DateTime? createdAt,
  }) async {
    final ts = (createdAt ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
    final existing = await _db.query(
      'outbox',
      where: 'doctype = ? AND mobile_uuid = ? AND state IN (?, ?, ?, ?)',
      whereArgs: [
        doctype,
        mobileUuid,
        OutboxState.pending.wireName,
        OutboxState.failed.wireName,
        OutboxState.blocked.wireName,
        OutboxState.conflict.wireName,
      ],
      orderBy: 'created_at ASC, id ASC',
    );

    if (operation == OutboxOperation.delete) {
      // DELETE collision rules: cancel any pending INSERT (with no
      // residual DELETE row), otherwise cancel UPDATEs and enqueue DELETE.
      final hasInsert = existing.any((r) => r['operation'] == 'INSERT');
      if (hasInsert) {
        await _db.delete(
          'outbox',
          where: 'doctype = ? AND mobile_uuid = ? AND state IN (?, ?, ?, ?)',
          whereArgs: [
            doctype,
            mobileUuid,
            OutboxState.pending.wireName,
            OutboxState.failed.wireName,
            OutboxState.blocked.wireName,
            OutboxState.conflict.wireName,
          ],
        );
        return RecordSaveResult.cancelledLocally;
      }
      await _db.delete(
        'outbox',
        where:
            'doctype = ? AND mobile_uuid = ? AND operation = ? '
            'AND state IN (?, ?, ?, ?)',
        whereArgs: [
          doctype,
          mobileUuid,
          'UPDATE',
          OutboxState.pending.wireName,
          OutboxState.failed.wireName,
          OutboxState.blocked.wireName,
          OutboxState.conflict.wireName,
        ],
      );
      await _db.insert('outbox', <String, Object?>{
        'doctype': doctype,
        'mobile_uuid': mobileUuid,
        'operation': operation.wireName,
        'state': OutboxState.pending.wireName,
        'created_at': ts,
      });
      return RecordSaveResult.enqueued;
    }

    if (operation == OutboxOperation.submit ||
        operation == OutboxOperation.cancel) {
      // SUBMIT/CANCEL never collapse — they're docstatus transitions
      // distinct from prior INSERT/UPDATE rows.
      await _db.insert('outbox', <String, Object?>{
        'doctype': doctype,
        'mobile_uuid': mobileUuid,
        'operation': operation.wireName,
        'state': OutboxState.pending.wireName,
        'created_at': ts,
      });
      return RecordSaveResult.enqueued;
    }

    // INSERT or UPDATE.
    final existingInsert = existing.firstWhere(
      (r) => r['operation'] == 'INSERT',
      orElse: () => const <String, Object?>{},
    );
    if (existingInsert.isNotEmpty) {
      await _db.update(
        'outbox',
        <String, Object?>{
          'state': OutboxState.pending.wireName,
          'error_code': null,
          'error_message': null,
        },
        where: 'id = ?',
        whereArgs: [existingInsert['id']],
      );
      return RecordSaveResult.enqueued;
    }
    final existingUpdate = existing.firstWhere(
      (r) => r['operation'] == 'UPDATE',
      orElse: () => const <String, Object?>{},
    );
    if (existingUpdate.isNotEmpty) {
      await _db.update(
        'outbox',
        <String, Object?>{
          'state': OutboxState.pending.wireName,
          'error_code': null,
          'error_message': null,
        },
        where: 'id = ?',
        whereArgs: [existingUpdate['id']],
      );
      return RecordSaveResult.enqueued;
    }
    await _db.insert('outbox', <String, Object?>{
      'doctype': doctype,
      'mobile_uuid': mobileUuid,
      'operation': operation.wireName,
      'state': OutboxState.pending.wireName,
      'created_at': ts,
    });
    return RecordSaveResult.enqueued;
  }

  /// Cancels every collapsable (non-in_flight, non-done) outbox row for
  /// this uuid. Used by [OfflineRepository.deleteDocument] when the
  /// caller wants to clear queued work explicitly.
  Future<void> cancelPendingFor({
    required String doctype,
    required String mobileUuid,
  }) async {
    await _db.delete(
      'outbox',
      where: 'doctype = ? AND mobile_uuid = ? AND state IN (?, ?, ?, ?)',
      whereArgs: [
        doctype,
        mobileUuid,
        OutboxState.pending.wireName,
        OutboxState.failed.wireName,
        OutboxState.blocked.wireName,
        OutboxState.conflict.wireName,
      ],
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

  /// Every outbox row queued for `(doctype, mobileUuid)` regardless of
  /// state, ordered oldest-first. Callers typically filter to non-`done`
  /// rows for UI surfacing.
  Future<List<OutboxRow>> findByMobileUuid({
    required String doctype,
    required String mobileUuid,
  }) async {
    final rows = await _db.query(
      'outbox',
      where: 'doctype = ? AND mobile_uuid = ?',
      whereArgs: [doctype, mobileUuid],
      orderBy: 'created_at ASC, id ASC',
    );
    return rows.map(OutboxRow.fromMap).toList();
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
      <String, Object?>{'state': OutboxState.inFlight.wireName},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Removes the outbox row outright. After a successful `_writeBack`,
  /// the operation is owed to nothing — keeping a `done` row would
  /// violate the "outbox holds only owed-to-server work" invariant.
  Future<void> markDone(int id, {required String serverName}) async {
    await _db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> markFailed(
    int id, {
    required ErrorCode errorCode,
    required String errorMessage,
  }) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.failed.wireName,
        'error_code': errorCode.wireName,
        'error_message': errorMessage,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> markConflict(int id, {String? errorMessage}) async {
    await _db.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.conflict.wireName,
        'error_code': ErrorCode.TIMESTAMP_MISMATCH.wireName,
        'error_message': errorMessage,
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
  /// `error_message` so retries start with a fresh slate. Used by
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
      [doctype, OutboxState.pending.wireName, OutboxState.inFlight.wireName],
    );
    return rows.isNotEmpty;
  }
}
