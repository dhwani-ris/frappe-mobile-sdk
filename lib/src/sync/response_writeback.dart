import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../database/schema/system_columns.dart';
import '../models/outbox_row.dart';
import 'push_error.dart';

/// Applies a successful Frappe push response to local state. Spec §5.2.
///
/// In a single transaction:
/// 1. Updates the parent row's `server_name`, `modified`, the server-owned
///    audit fields the response carried ([serverAuditColumnNames]), sets
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
    // DELETE: server sends no body. Hard-delete the local mirror and outbox
    // row — the tombstone is no longer needed once the server confirms.
    if (row.operation == OutboxOperation.delete) {
      await txn.delete(
        parentTable,
        where: 'mobile_uuid = ?',
        whereArgs: [row.mobileUuid],
      );
      for (final tableName in childTablesByFieldname.values) {
        await txn.delete(
          tableName,
          where: 'parent_uuid = ?',
          whereArgs: [row.mobileUuid],
        );
      }
      await txn.delete('outbox', where: 'id = ?', whereArgs: [row.id]);
      return;
    }

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

    // Frappe assigns `owner` / `creation` on insert and `modified_by` on every
    // save, and the push response is the first place a client legitimately
    // learns the AUTHORITATIVE values for a doc it just created.
    //
    // A device-created row already carries a local PREDICTION of these fields
    // (`LocalWriter._resolveParentAudit` stamps the session user + now, so the
    // creator's own `owner = <me>` list works before any sync). This writeback
    // replaces that prediction with the server's own values the moment the push
    // succeeds, instead of leaving it to stand until the next full pull. If the
    // server ever disagrees with the prediction — e.g. a server-side hook
    // reassigns `owner` — this is what converges the mirror.
    // Written regardless of [hasMore]: queued local edits can never change
    // these fields, so the server's value is correct either way.
    //
    // Deliberately UNLIKE `PullApply._copyServerAuditFields`, which keys off
    // `containsKey` and therefore copies an explicit null: here an omitted key
    // (or a null/empty value) is SKIPPED. A lean update response that does not
    // echo these must not blank what an earlier pull correctly persisted.
    // `?.toString()` rather than `as String?` — a non-string value from a
    // custom controller must not raise a TypeError inside the push writeback.
    final auditValues = <String, Object?>{};
    for (final col in serverAuditColumnNames) {
      final value = response[col]?.toString();
      if (value == null || value.isEmpty) continue;
      auditValues[col] = value;
    }
    if (auditValues.isNotEmpty) {
      // These columns are emitted by `buildParentSchemaDDL` and backfilled by
      // `AppDatabase._migrateV5ToV6` + `reconcileParentTableForMeta`, so they
      // are present in practice. But a table provisioned outside those paths
      // would make the UPDATE below throw `no such column`, rolling back the
      // ENTIRE writeback and leaving the outbox row to re-push a document the
      // server already accepted — far worse than a missing `owner`. Filter
      // against the live schema, the same guard PushEngine's merge path uses.
      // One PRAGMA (an in-memory schema read), and only when the response
      // actually carried something to write.
      final tableCols = (await txn.rawQuery(
        'PRAGMA table_info("$parentTable")',
      )).map((r) => r['name'] as String?).toSet();
      auditValues.removeWhere((col, _) => !tableCols.contains(col));
    }

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
        ...auditValues,
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
          updated = await txn.update(
            tableName,
            values,
            where: 'parent_uuid = ? AND parentfield = ? AND idx = ?',
            whereArgs: [row.mobileUuid, fieldname, pos],
          );
        }
        if (updated == 0) {
          // Neither the mobile_uuid match nor the positional fallback found a
          // local row — the server echoed a child we cannot tie back to local
          // state (mobile_uuid not round-tripped AND response order diverged
          // from local idx). Its server_name writeback is dropped, so the row
          // looks unsynced and re-pushes next drain. Should never happen for a
          // row the server just echoed; surface it instead of failing silently
          // (PR#36 round-4 H2).
          debugPrint(
            'ResponseWriteback: no local row matched server child '
            "'${cm['name']}' (parentfield=$fieldname, pos=$pos, "
            'mobile_uuid=$childMobileUuid) under parent ${row.mobileUuid}; '
            'server_name writeback dropped — row will re-push next sync.',
          );
        }
      }
    }

    // Outbox holds only owed-to-server work (Invariant 2). Delete the
    // row outright instead of marking it `done`.
    await txn.delete('outbox', where: 'id = ?', whereArgs: [row.id]);
  }
}
