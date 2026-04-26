import 'package:sqflite/sqflite.dart';

import '../models/outbox_row.dart';

/// Applies a successful Frappe push response to local state. Spec §5.2.
///
/// In a single transaction:
/// 1. Updates the parent row's `server_name`, `modified`, sets
///    `sync_status='synced'`, clears error fields.
/// 2. For each child table, matches existing local rows by
///    `(parent_uuid, parentfield, idx)` and writes back the server's
///    `name` + `modified` for that idx slot.
/// 3. Flips the originating outbox row to `done`, stamping its
///    `server_name` and `last_attempt_at`.
class ResponseWriteback {
  /// Apply in a fresh `db.transaction(...)`. Use this when no surrounding
  /// transaction is active (tests, single-shot callers). PushEngine routes
  /// through [WriteQueue] in production, which calls [applyInTxn] directly.
  static Future<void> apply({
    required Database db,
    required OutboxRow row,
    required String parentTable,
    required Map<String, String> childTablesByFieldname,
    required Map<String, dynamic> response,
  }) async {
    await db.transaction((txn) async {
      await applyInTxn(
        txn: txn,
        row: row,
        parentTable: parentTable,
        childTablesByFieldname: childTablesByFieldname,
        response: response,
      );
    });
  }

  /// Apply using a caller-supplied transaction. PushEngine's WriteQueue
  /// path uses this so we don't nest `db.transaction(...)` (sqflite would
  /// deadlock).
  static Future<void> applyInTxn({
    required Transaction txn,
    required OutboxRow row,
    required String parentTable,
    required Map<String, String> childTablesByFieldname,
    required Map<String, dynamic> response,
  }) async {
    final serverName = response['name'] as String;
    final serverModified = response['modified'] as String?;
    await txn.update(
      parentTable,
      <String, Object?>{
        'server_name': serverName,
        'modified': serverModified,
        'sync_status': 'synced',
        'sync_error': null,
        'sync_attempts': 0,
      },
      where: 'mobile_uuid = ?',
      whereArgs: [row.mobileUuid],
    );

    for (final entry in childTablesByFieldname.entries) {
      final fieldname = entry.key;
      final tableName = entry.value;
      final childList = response[fieldname] as List?;
      if (childList == null) continue;
      for (final c in childList) {
        final cm = Map<String, dynamic>.from(c as Map);
        await txn.update(
          tableName,
          <String, Object?>{
            'server_name': cm['name'],
            'modified': cm['modified'],
          },
          where: 'parent_uuid = ? AND parentfield = ? AND idx = ?',
          whereArgs: [row.mobileUuid, fieldname, cm['idx']],
        );
      }
    }

    await txn.update(
      'outbox',
      <String, Object?>{
        'state': OutboxState.done.wireName,
        'server_name': serverName,
        'last_attempt_at':
            DateTime.now().toUtc().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [row.id],
    );
  }
}
