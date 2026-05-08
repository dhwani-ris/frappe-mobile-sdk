import 'package:sqflite/sqflite.dart';

import '../models/outbox_row.dart';
import 'push_error.dart';

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
    // Frappe usually returns the server-assigned id as `name`. Some
    // endpoints (custom controllers, file upload, older versions) return
    // it as `docname` instead — accept either. If neither is present the
    // response is malformed; raise a structured error so the outbox row
    // is marked failed cleanly instead of crashing the WriteQueue task.
    final serverName = (response['name'] ?? response['docname']) as String?;
    if (serverName == null || serverName.isEmpty) {
      throw ServerRejection(
        status: 0,
        rawBody: 'Push response missing both "name" and "docname"',
      );
    }
    final serverModified = response['modified'] as String?;

    // Are any other non-done outbox rows pending for this uuid? If so,
    // leave sync_status='dirty' so the next push picks them up — flipping
    // to 'synced' would falsely advertise the doc is in sync with the
    // server while local edits remain queued. Spec §"In-flight collision
    // handling".
    final more = await txn.rawQuery(
      '''
      SELECT 1 FROM outbox
       WHERE doctype = ?
         AND mobile_uuid = ?
         AND id != ?
         AND state IN (?, ?, ?, ?, ?)
       LIMIT 1
      ''',
      [
        row.doctype,
        row.mobileUuid,
        row.id,
        OutboxState.pending.wireName,
        OutboxState.inFlight.wireName,
        OutboxState.failed.wireName,
        OutboxState.blocked.wireName,
        OutboxState.conflict.wireName,
      ],
    );
    final hasMore = more.isNotEmpty;

    await txn.update(
      parentTable,
      <String, Object?>{
        'server_name': serverName,
        'modified': serverModified,
        'sync_status': hasMore ? 'dirty' : 'synced',
        if (!hasMore) 'sync_error': null,
        if (!hasMore) 'error_code': null,
        if (!hasMore) 'push_base_payload': null,
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
      // Match priority:
      //   1. mobile_uuid — when mobile_control echoes it back, the
      //      most stable key.
      //   2. Position in the response list (0-based) against the
      //      local row's idx. Frappe's `base_document.append`
      //      overwrites idx=0 → 1 because `getattr(d, "idx", False)`
      //      treats 0 as falsy, so matching on `cm['idx']` directly
      //      silently misses the local row.
      for (var pos = 0; pos < childList.length; pos++) {
        final cm = Map<String, dynamic>.from(childList[pos] as Map);
        final values = <String, Object?>{
          'server_name': cm['name'],
          'modified': cm['modified'],
        };
        var updated = 0;
        final childMobileUuid = cm['mobile_uuid']?.toString();
        if (childMobileUuid != null && childMobileUuid.isNotEmpty) {
          updated = await txn.update(
            tableName,
            values,
            where: 'mobile_uuid = ?',
            whereArgs: [childMobileUuid],
          );
        }
        if (updated == 0) {
          await txn.update(
            tableName,
            values,
            where: 'parent_uuid = ? AND parentfield = ? AND idx = ?',
            whereArgs: [row.mobileUuid, fieldname, pos],
          );
        }
      }
    }

    // Outbox holds only owed-to-server work (Invariant 2). Delete the
    // row outright instead of marking it `done`.
    await txn.delete('outbox', where: 'id = ?', whereArgs: [row.id]);
  }
}
