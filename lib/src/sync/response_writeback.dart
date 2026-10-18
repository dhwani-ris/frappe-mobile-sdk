import 'package:sqflite/sqflite.dart';

import '../database/schema/system_columns.dart';
import '../models/doc_type_meta.dart';
import '../models/outbox_row.dart';
import '../utils/sdk_log.dart';
import 'pull_apply.dart' show isServerMirroredField, putServerFieldValue;
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
///
/// Opt-in server-field writeback: when a `writeBackMeta` is passed (PushEngine
/// does so for the doctypes in `FrappeSDK.writeBackDoctypes`), every field of
/// the returned document that has a column in the local mirror is also
/// written, parent and children, so values the server computed on save
/// (naming-series fields, totals, a status set by a controller, a signature)
/// are visible locally at once instead of after the next pull. See
/// [_serverFieldValues] for what is and is not written.
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
    DocTypeMeta? writeBackMeta,
    Map<String, DocTypeMeta> writeBackChildMetas = const {},
  }) async {
    await db.transaction((txn) async {
      await applyInTxn(
        txn: txn,
        row: row,
        parentTable: parentTable,
        childTablesByFieldname: childTablesByFieldname,
        response: response,
        writeBackMeta: writeBackMeta,
        writeBackChildMetas: writeBackChildMetas,
      );
    });
  }

  /// Apply using a caller-supplied transaction. PushEngine's WriteQueue
  /// path uses this so we don't nest `db.transaction(...)` (sqflite would
  /// deadlock).
  ///
  /// [writeBackMeta] turns on the server-field writeback for this row: the
  /// parent doctype's meta, used to decide which response keys are fields
  /// with a local column. [writeBackChildMetas] does the same for child rows,
  /// keyed by the parent's Table fieldname (a child table with no entry gets
  /// only `server_name` / `modified`, as before). With [writeBackMeta] null
  /// (the default) the writeback is exactly what it was.
  static Future<void> applyInTxn({
    required Transaction txn,
    required OutboxRow row,
    required String parentTable,
    required Map<String, String> childTablesByFieldname,
    required Map<String, dynamic> response,
    DocTypeMeta? writeBackMeta,
    Map<String, DocTypeMeta> writeBackChildMetas = const {},
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

    // Server-field writeback is skipped as a whole while more local work is
    // queued for this doc ([hasMore]). A save made while this push was in
    // flight always queues a fresh outbox row (`OutboxDao.recordSave` never
    // collapses into an `in_flight` row), so [hasMore] is exactly "the user
    // edited this doc after the payload we just sent was assembled". The
    // server's copy of a field may then be older than the local one, and we
    // cannot tell which fields were touched, so none are written: the queued
    // push sends the local edits and ITS response carries the server-computed
    // values. Same rule as `sync_status` staying `dirty` below.
    final writeServerFields = writeBackMeta != null && !hasMore;
    // Live column set per table, read once per writeback (children would
    // otherwise re-read it for every row).
    final columnsByTable = <String, Set<String?>>{};

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

    final parentFieldValues = writeServerFields
        ? await _serverFieldValues(
            txn: txn,
            table: parentTable,
            meta: writeBackMeta,
            systemColumns: systemParentColumnNames,
            doc: response,
            normFields: writeBackMeta.normFieldNames,
            columnsByTable: columnsByTable,
          )
        : const <String, Object?>{};

    await txn.update(
      parentTable,
      <String, Object?>{
        // First, so the sync bookkeeping below always wins. The helper
        // already excludes every system column; this is belt and braces.
        ...parentFieldValues,
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
      final childMeta = writeServerFields
          ? writeBackChildMetas[fieldname]
          : null;
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
          if (childMeta != null)
            ...await _serverFieldValues(
              txn: txn,
              table: tableName,
              meta: childMeta,
              systemColumns: systemChildColumnNames,
              doc: cm,
              columnsByTable: columnsByTable,
            ),
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
          sdkLog(
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

  /// The column values to write for the server-field writeback of one
  /// document [doc] (a parent response or one of its child rows) into
  /// [table].
  ///
  /// Written: every field of [meta] that [isServerMirroredField] accepts
  /// (not a system / sync-metadata column such as `mobile_uuid`,
  /// `sync_status`, `docstatus`, `modified` or the audit fields, which the
  /// caller handles itself) AND whose key is present in [doc]. Values go
  /// through [putServerFieldValue], the same conversion a pull uses, so a
  /// Link gets `__is_local = 0` and a search field its `__norm` column.
  ///
  /// Not written:
  /// * keys [doc] does not carry — a lean response must not blank a column
  ///   (an explicit null IS written: that is the server's value);
  /// * keys that are not fields of [meta] — unknown to this device;
  /// * columns the live table does not have (meta newer than the schema),
  ///   filtered with one `PRAGMA table_info` per table (cached in
  ///   [columnsByTable]), so the UPDATE can never fail
  ///   with `no such column` and roll back the whole writeback;
  /// * a `Map` / `List` value (SQLite cannot bind it; it would roll back the
  ///   writeback and re-push a document the server already accepted). Logged
  ///   by fieldname only, never the value.
  static Future<Map<String, Object?>> _serverFieldValues({
    required Transaction txn,
    required String table,
    required DocTypeMeta meta,
    required Set<String> systemColumns,
    required Map<String, dynamic> doc,
    required Map<String, Set<String?>> columnsByTable,
    Set<String> normFields = const <String>{},
  }) async {
    final out = <String, Object?>{};
    for (final field in meta.fields) {
      if (!isServerMirroredField(field, systemColumns)) continue;
      final name = field.fieldname!;
      if (!doc.containsKey(name)) continue;
      final value = doc[name];
      if (value is Map || value is List) {
        sdkLog(
          'ResponseWriteback: skipped server value for $table.$name '
          '(${value.runtimeType} cannot be stored in a column).',
        );
        continue;
      }
      putServerFieldValue(
        into: out,
        field: field,
        value: value,
        normFields: normFields,
      );
    }
    if (out.isEmpty) return out;
    final tableCols = columnsByTable[table] ??= (await txn.rawQuery(
      'PRAGMA table_info("$table")',
    )).map((r) => r['name'] as String?).toSet();
    out.removeWhere((col, _) => !tableCols.contains(col));
    return out;
  }
}
