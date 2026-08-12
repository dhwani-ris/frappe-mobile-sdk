import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/field_type_mapping.dart';
import '../database/normalize_for_search.dart';
import '../database/schema/system_columns.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../utils/sdk_log.dart';
import 'child_table_info.dart';

/// Frappe returns `modified` as `"YYYY-MM-DD HH:MM:SS.ffffff"` with no
/// timezone suffix. `DateTime.tryParse` interprets such tz-naive strings
/// as device-local time, which makes any cross-call comparison brittle:
/// DST transitions, device tz changes, or future code that compares
/// against `DateTime.now().toUtc()` will all drift. Normalize to UTC
/// explicitly by appending `Z` when no offset is present.
@visibleForTesting
String? parseFrappeUtcStringForTest(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return _asUtc(raw);
}

DateTime? _parseFrappeUtc(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(_asUtc(raw));
}

String _asUtc(String raw) {
  // Already has a timezone designator?
  if (raw.endsWith('Z')) return raw;
  if (raw.contains('+')) return raw;
  if (RegExp(r'-\d{2}:\d{2}$').hasMatch(raw)) return raw;
  // Date-only string (e.g. `2026-02-01`) — Dart's DateTime.tryParse
  // rejects `YYYY-MM-DDZ`, so leave as-is. Two such strings still order
  // consistently because both parse with the same local-midnight offset.
  if (!raw.contains(':')) return raw;
  return '${raw}Z';
}

/// System columns that the per-doctype mirror manages itself. A meta field
/// that shares one of these names (e.g. `mobile_uuid` exposed for L2
/// idempotency, or Frappe's stock `modified` / `docstatus`) must not be
/// allowed to overwrite the system-set value during the meta loop --
/// `mobile_uuid` is the local PK and would PK-collide on the next empty
/// string the server returns. Sourced from
/// `database/schema/system_columns.dart` so all three writers (DDL, form-save,
/// pull-apply) cannot drift apart.
const _systemParentColumnNames = systemParentColumnNames;

/// System columns the child mirror manages itself. Same rationale.
const _systemChildColumnNames = systemChildColumnNames;

/// Parent `sync_status` values that mean "local has unpushed work". When a
/// pulled row's local copy is in any of these states, [PullApply] preserves
/// the local payload (and its child rows -- see the C3 gate at the
/// child-wipe site below) instead of overwriting with the server snapshot.
/// Children deliberately have no `sync_status` column of their own; they
/// inherit the parent's state via this gate.
const _locallyDirtyStatuses = <String>[
  'dirty',
  'failed',
  'conflict',
  'blocked',
];

/// Copies Frappe's server-owned audit fields ([serverAuditColumnNames]) from
/// a pulled server row [from] into the `docs__<doctype>` row map [into].
///
/// Only keys the server actually sent are copied. That matters for the
/// sequential path, whose UPDATE leaves an omitted column untouched: a page
/// fetched without these fields must not blank values an earlier pull already
/// persisted. Nothing is ever invented locally — the server is their only
/// writer. Called BEFORE the meta loop, which skips these names (they are in
/// [systemParentColumnNames]) so a duplicate field declaration cannot reach
/// back and clobber what the server sent.
void _copyServerAuditFields({
  required Map<String, dynamic> from,
  required Map<String, Object?> into,
}) {
  for (final col in serverAuditColumnNames) {
    if (!from.containsKey(col)) continue;
    into[col] = from[col];
  }
}

/// Back-compat alias for [ChildTableInfo]. Retained so existing call
/// sites (`offline_repository.dart`, `pull_engine.dart`, the test suite)
/// keep compiling after the M1/D2 consolidation.
typedef PullApplyChildInfo = ChildTableInfo;

/// Applies a fetched page of rows transactionally. Spec §5.1.
///
/// For each row:
/// 1. Look up by `server_name`. If existing row has
///    `sync_status IN (dirty, failed, conflict)` and the server has
///    advanced, flag as `conflict` and preserve the local payload — the
///    push engine handles resolution.
/// 2. Otherwise UPSERT, preserving `mobile_uuid` if already assigned.
/// 3. For each child-table field declared in [childMetasByFieldname],
///    fully replace the parent's children: delete all rows for that
///    `(parent_uuid, parentfield)` slot, then insert the new list with
///    fresh `idx` values.
/// 4. `__norm` columns are populated for title_field + every searchField.
/// 5. `__is_local` is set to 0 for every Link field on the row (server
///    values are not local UUIDs).
class PullApply {
  /// Apply a page in a fresh `db.transaction(...)`. Used by callers that
  /// don't have a transaction in hand (e.g. unit tests, single-shot
  /// applies). PullEngine routes through [WriteQueue] in production, which
  /// calls [applyPageInTxn] directly.
  static Future<void> applyPage({
    required Database db,
    required DocTypeMeta parentMeta,
    required String parentTable,
    required Map<String, PullApplyChildInfo> childMetasByFieldname,
    required List<Map<String, dynamic>> rows,
    bool isInitialSync = false,
  }) async {
    await db.transaction((txn) async {
      await applyPageInTxn(
        txn: txn,
        parentMeta: parentMeta,
        parentTable: parentTable,
        childMetasByFieldname: childMetasByFieldname,
        rows: rows,
        isInitialSync: isInitialSync,
      );
    });
  }

  /// Apply a page using a caller-supplied transaction. Use this when a
  /// surrounding [WriteQueue] already has an active transaction so we
  /// don't nest `db.transaction(...)` calls (sqflite would deadlock).
  static Future<void> applyPageInTxn({
    required Transaction txn,
    required DocTypeMeta parentMeta,
    required String parentTable,
    required Map<String, PullApplyChildInfo> childMetasByFieldname,
    required List<Map<String, dynamic>> rows,
    bool isInitialSync = false,
  }) async {
    final uuidGen = const Uuid();
    final parentNormFields = parentMeta.normFieldNames;

    if (isInitialSync) {
      // Bulk path is an optimisation for the clean-slate initial sync —
      // it skips per-row queries. Before using it, check whether any
      // existing rows need the sequential guards (tombstone skip,
      // dirty-row conflict detection, ghost-success UUID reconciliation).
      // If any such rows exist, fall back to the sequential path for the
      // entire page. The pre-check is a single COUNT query, O(1).
      final serverNames = rows
          .map((r) => r['name'] as String?)
          .where((n) => n != null && n.isNotEmpty)
          .cast<String>()
          .toList();
      final incomingUuids = rows
          .map((r) => r['mobile_uuid']?.toString())
          .where((u) => u != null && u.isNotEmpty)
          .cast<String>()
          .toList();

      var useSequential = false;
      if (serverNames.isNotEmpty) {
        final dirtyStatuses = [..._locallyDirtyStatuses, 'deleted'];
        final snPlaceholders = List.filled(serverNames.length, '?').join(',');
        final dirtyPlaceholders = List.filled(
          dirtyStatuses.length,
          '?',
        ).join(',');

        final String query;
        final List<Object?> args;
        if (incomingUuids.isNotEmpty) {
          final uuidPlaceholders = List.filled(
            incomingUuids.length,
            '?',
          ).join(',');
          query =
              '''
            SELECT COUNT(*) AS n FROM $parentTable
            WHERE (server_name IN ($snPlaceholders)
                   AND sync_status IN ($dirtyPlaceholders))
               OR (mobile_uuid IN ($uuidPlaceholders)
                   AND (server_name IS NULL OR server_name = ''))
          ''';
          args = [...serverNames, ...dirtyStatuses, ...incomingUuids];
        } else {
          query =
              '''
            SELECT COUNT(*) AS n FROM $parentTable
            WHERE server_name IN ($snPlaceholders)
              AND sync_status IN ($dirtyPlaceholders)
          ''';
          args = [...serverNames, ...dirtyStatuses];
        }

        final result = await txn.rawQuery(query, args);
        final unsafeCount = (result.first['n'] as int? ?? 0);
        if (unsafeCount > 0) {
          sdkLog(
            'PullApply.applyPageInTxn: $unsafeCount unsafe rows detected'
            ' — falling back to sequential for $parentTable',
          );
          useSequential = true;
        }
      }

      if (!useSequential) {
        sdkLog(
          'PullApply.applyPageInTxn: Bulk insert of ${rows.length} rows'
          ' into $parentTable',
        );
        await _applyPageInTxnBulk(
          txn: txn,
          parentMeta: parentMeta,
          parentTable: parentTable,
          childMetasByFieldname: childMetasByFieldname,
          rows: rows,
          uuidGen: uuidGen,
          parentNormFields: parentNormFields,
        );
        return;
      }
    }
    // Sequential path — handles all edge cases. Used for incremental
    // sync and for initial-sync pages that failed the bulk safety check.
    sdkLog(
      'PullApply.applyPageInTxn: Sequential write of ${rows.length} rows'
      ' into $parentTable',
    );
    await _applyPageInTxnSequential(
      txn: txn,
      parentMeta: parentMeta,
      parentTable: parentTable,
      childMetasByFieldname: childMetasByFieldname,
      rows: rows,
      uuidGen: uuidGen,
      parentNormFields: parentNormFields,
    );
  }

  static Future<void> _applyPageInTxnSequential({
    required Transaction txn,
    required DocTypeMeta parentMeta,
    required String parentTable,
    required Map<String, PullApplyChildInfo> childMetasByFieldname,
    required List<Map<String, dynamic>> rows,
    required Uuid uuidGen,
    required Set<String> parentNormFields,
  }) async {
    final batch = txn.batch();
    for (final r in rows) {
      final serverName = r['name'] as String?;
      if (serverName == null) continue;

      var existing = await txn.query(
        parentTable,
        columns: ['mobile_uuid', 'sync_status', 'modified', 'server_name'],
        where: 'server_name = ?',
        whereArgs: [serverName],
        limit: 1,
      );

      // Fallback match by mobile_uuid. When a push INSERT has committed
      // server-side but its local writeback hasn't stamped `server_name`
      // yet, the server_name lookup misses. The pulled mobile-origin row
      // carries the same `mobile_uuid` the device assigned (server stores
      // it as a unique field that round-trips), so match on that to update
      // the existing row in place instead of inserting a duplicate.
      // Desk-origin rows have an empty mobile_uuid and never hit this path.
      var matchedByUuid = false;
      if (existing.isEmpty) {
        final incomingUuid = r['mobile_uuid']?.toString();
        if (incomingUuid != null && incomingUuid.isNotEmpty) {
          existing = await txn.query(
            parentTable,
            columns: ['mobile_uuid', 'sync_status', 'modified', 'server_name'],
            where: 'mobile_uuid = ?',
            whereArgs: [incomingUuid],
            limit: 1,
          );
          matchedByUuid = existing.isNotEmpty;
        }
      }

      // UUID-uniqueness assumption: `mobile_uuid` is a v4 UUID minted on this
      // device and treated as globally unique, so a fallback match means *this*
      // device created the row. We deliberately do NOT add a hard consistency
      // assertion against the incoming server row — it would mis-fire on
      // legitimate server-side edits and risk dropping good data. As a
      // non-fatal tripwire we log (never block) when a uuid-matched local row
      // is already bound to a *different* server_name: that mismatch is the
      // only observable signature of a cross-device UUID clash or a bad data
      // migration reusing a mobile_uuid. The incoming row is still applied.
      if (matchedByUuid) {
        final priorServerName = existing.first['server_name'] as String?;
        if (priorServerName != null &&
            priorServerName.isNotEmpty &&
            priorServerName != serverName) {
          sdkLog(
            'PullApply: mobile_uuid "${r['mobile_uuid']}" matched a local row '
            'in $parentTable already bound to server_name "$priorServerName", '
            'but the incoming server row is "$serverName" — possible UUID reuse '
            '/ cross-device collision; applying the incoming row.',
          );
        }
      }

      // Tombstoned rows never resurrect — local DELETE is queued in
      // outbox waiting to push. Skip silently; once the DELETE outbox
      // row drains, the row is hard-deleted server-side too.
      if (existing.isNotEmpty && existing.first['sync_status'] == 'deleted') {
        continue;
      }
      // False-conflict guard: a row matched via the mobile_uuid fallback
      // whose local `server_name` is still NULL is our own INSERT
      // round-tripping (push committed server-side, writeback pending) —
      // reconcile it (stamp server_name, mark synced) instead of flagging a
      // spurious conflict. server_name matches never set matchedByUuid, so
      // genuine server-side edits to synced docs still flag conflict.
      final localServerName = existing.isEmpty
          ? null
          : existing.first['server_name'] as String?;
      bool isOwnInsertRoundtrip =
          matchedByUuid && (localServerName == null || localServerName.isEmpty);
      if (isOwnInsertRoundtrip && existing.isNotEmpty) {
        // Confirm no owed outbox work — if there is, local edits may have
        // diverged (e.g. a ghost-success push left server_name NULL while
        // the user made further edits). Overwriting here would cause data
        // loss. Check for any non-done, non-in_flight outbox rows.
        final mobileUuid = existing.first['mobile_uuid'] as String? ?? '';
        if (mobileUuid.isNotEmpty) {
          final pendingWork = await txn.rawQuery(
            "SELECT id FROM outbox WHERE mobile_uuid = ? "
            "AND state NOT IN ('done','in_flight') LIMIT 1",
            [mobileUuid],
          );
          if (pendingWork.isNotEmpty) {
            // Local work still owed; don't overwrite the local payload. But the
            // server HAS this row (it round-tripped our mobile_uuid), so stamp
            // its server_name now — otherwise the conflict guard below updates
            // sync_status and `continue`s, leaving the row with a NULL
            // server_name that can never be pushed/resolved.
            batch.update(
              parentTable,
              {'server_name': serverName},
              where: 'mobile_uuid = ?',
              whereArgs: [mobileUuid],
            );
            isOwnInsertRoundtrip = false;
          }
        }
      }
      if (existing.isNotEmpty &&
          !isOwnInsertRoundtrip &&
          _locallyDirtyStatuses.contains(existing.first['sync_status'])) {
        // Spec §5.1 requires "server has advanced" before flagging a
        // conflict. Cursor filtering normally guarantees this, but
        // defending here prevents spurious conflicts on initial sync,
        // cursor reset, and look-ahead pages where a row may resurface
        // with the same `modified` we already hold.
        final storedModified = _parseFrappeUtc(
          existing.first['modified'] as String?,
        );
        final incomingModified = _parseFrappeUtc(r['modified'] as String?);
        final serverAdvanced =
            incomingModified != null &&
            (storedModified == null ||
                incomingModified.isAfter(storedModified));
        if (serverAdvanced) {
          batch.update(
            parentTable,
            <String, Object?>{
              'sync_status': 'conflict',
              'sync_error': 'server_modified=${r['modified'] ?? ''}',
            },
            where: 'mobile_uuid = ?',
            whereArgs: [existing.first['mobile_uuid']],
          );
        }
        continue;
      }

      final uuid = existing.isEmpty
          ? uuidGen.v4()
          : existing.first['mobile_uuid'] as String;

      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final parentRow = <String, Object?>{
        'mobile_uuid': uuid,
        'server_name': serverName,
        'sync_status': 'synced',
        // Mirror server-side docstatus/modified; the meta loop below skips
        // these so a duplicate field declaration cannot reach back and
        // clobber the values we set here.
        'docstatus': r['docstatus'] ?? 0,
        'modified': r['modified'],
        'local_modified': nowMs,
        'pulled_at': nowMs,
      };
      _copyServerAuditFields(from: r, into: parentRow);

      for (final f in parentMeta.fields) {
        final name = f.fieldname;
        final type = f.fieldtype;
        if (name == null) continue;
        if (type == 'Table' || type == 'Table MultiSelect') continue;
        if (sqliteColumnTypeFor(type) == null) continue;
        if (_systemParentColumnNames.contains(name)) continue;
        final v = r[name];
        parentRow[name] = v;
        if (isLinkFieldType(type)) {
          parentRow['${name}__is_local'] = 0;
        }
        if (parentNormFields.contains(name) &&
            sqliteColumnTypeFor(type) == 'TEXT') {
          parentRow['${name}__norm'] = normalizeForSearch(v?.toString());
        }
      }

      if (existing.isEmpty) {
        batch.insert(parentTable, parentRow);
      } else {
        batch.update(
          parentTable,
          parentRow,
          where: 'mobile_uuid = ?',
          whereArgs: [uuid],
        );
      }

      // C3 gate: the child wipe below is only reached when the parent's
      // local `sync_status` is NOT in `_locallyDirtyStatuses` -- the early
      // `continue` above filters dirty/failed/conflict/blocked parents
      // before we get here. Children inherit the parent's status (see
      // `child_schema.dart`), so a dirty parent shields its child rows from
      // the pull's destructive replace. Do not introduce a code path that
      // reaches this loop with a locally-dirty parent.
      for (final entry in childMetasByFieldname.entries) {
        final fieldname = entry.key;
        final childInfo = entry.value;
        final childTable = normalizeDoctypeTableName(childInfo.doctype);
        final list = (r[fieldname] as List?) ?? const [];

        // Snapshot existing local children before the wipe so we can
        // preserve their mobile_uuid. Cross-doc Link fields point at
        // this uuid; a fresh v4 on every re-pull orphans them.
        // Priority: server_name → mobile_uuid → position (0-based).
        final existingChildren = await txn.query(
          childTable,
          columns: ['mobile_uuid', 'server_name'],
          where: 'parent_uuid = ? AND parentfield = ?',
          whereArgs: [uuid, fieldname],
          orderBy: 'idx ASC',
        );
        final byServerName = <String, String>{};
        final byPosition = <int, String>{};
        final localUuids = <String>{};
        for (var i = 0; i < existingChildren.length; i++) {
          final ec = existingChildren[i];
          final mu = ec['mobile_uuid'] as String?;
          if (mu == null || mu.isEmpty) continue;
          byPosition[i] = mu;
          localUuids.add(mu);
          final sn = ec['server_name'] as String?;
          if (sn != null && sn.isNotEmpty) byServerName[sn] = mu;
        }

        batch.delete(
          childTable,
          where: 'parent_uuid = ? AND parentfield = ?',
          whereArgs: [uuid, fieldname],
        );

        for (var idx = 0; idx < list.length; idx++) {
          final cr = Map<String, dynamic>.from(list[idx] as Map);
          final serverChildName = cr['name'] as String?;
          final rawChildUuid = cr['mobile_uuid']?.toString();
          final hasRawUuid = rawChildUuid != null && rawChildUuid.isNotEmpty;
          String? preserved;
          if (serverChildName != null && serverChildName.isNotEmpty) {
            preserved = byServerName[serverChildName];
          }
          if (preserved == null &&
              hasRawUuid &&
              localUuids.contains(rawChildUuid)) {
            preserved = rawChildUuid;
          }
          preserved ??= byPosition[idx];
          final childUuid =
              preserved ?? (hasRawUuid ? rawChildUuid : uuidGen.v4());
          final childRow = <String, Object?>{
            'mobile_uuid': childUuid,
            'server_name': serverChildName,
            'parent_uuid': uuid,
            'parent_doctype': parentMeta.name,
            'parentfield': fieldname,
            'idx': idx,
            'modified': cr['modified'] as String?,
          };
          for (final cf in childInfo.meta.fields) {
            final cn = cf.fieldname;
            final ct = cf.fieldtype;
            if (cn == null) continue;
            if (sqliteColumnTypeFor(ct) == null) continue;
            if (_systemChildColumnNames.contains(cn)) continue;
            childRow[cn] = cr[cn];
            if (isLinkFieldType(ct)) {
              childRow['${cn}__is_local'] = 0;
            }
          }
          batch.insert(childTable, childRow);
        }
      }
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _applyPageInTxnBulk({
    required Transaction txn,
    required DocTypeMeta parentMeta,
    required String parentTable,
    required Map<String, PullApplyChildInfo> childMetasByFieldname,
    required List<Map<String, dynamic>> rows,
    required Uuid uuidGen,
    required Set<String> parentNormFields,
  }) async {
    final serverNames = rows
        .map((r) => r['name'] as String?)
        .where((n) => n != null && n.isNotEmpty)
        .cast<String>()
        .toList();

    if (serverNames.isEmpty) return;

    // Fetch existing UUIDs for mid-sync resumes where rows might already exist.
    final existingUuids = <String, String>{};
    const chunkSize = 500;
    for (var i = 0; i < serverNames.length; i += chunkSize) {
      final chunk = serverNames.sublist(
        i,
        i + chunkSize > serverNames.length ? serverNames.length : i + chunkSize,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      final res = await txn.query(
        parentTable,
        columns: ['server_name', 'mobile_uuid'],
        where: 'server_name IN ($placeholders)',
        whereArgs: chunk,
      );
      for (final row in res) {
        final sn = row['server_name'] as String?;
        final mu = row['mobile_uuid'] as String?;
        if (sn != null && mu != null) {
          existingUuids[sn] = mu;
        }
      }
    }

    final batch = txn.batch();
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

    for (final r in rows) {
      final serverName = r['name'] as String?;
      if (serverName == null || serverName.isEmpty) continue;

      final uuid = existingUuids[serverName] ?? uuidGen.v4();

      final parentRow = <String, Object?>{
        'mobile_uuid': uuid,
        'server_name': serverName,
        'sync_status': 'synced',
        'docstatus': r['docstatus'] ?? 0,
        'modified': r['modified'],
        'local_modified': nowMs,
        'pulled_at': nowMs,
      };
      _copyServerAuditFields(from: r, into: parentRow);

      for (final f in parentMeta.fields) {
        final name = f.fieldname;
        final type = f.fieldtype;
        if (name == null) continue;
        if (type == 'Table' || type == 'Table MultiSelect') continue;
        if (sqliteColumnTypeFor(type) == null) continue;
        if (_systemParentColumnNames.contains(name)) continue;
        final v = r[name];
        parentRow[name] = v;
        if (isLinkFieldType(type)) {
          parentRow['${name}__is_local'] = 0;
        }
        if (parentNormFields.contains(name) &&
            sqliteColumnTypeFor(type) == 'TEXT') {
          parentRow['${name}__norm'] = normalizeForSearch(v?.toString());
        }
      }

      batch.insert(
        parentTable,
        parentRow,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final entry in childMetasByFieldname.entries) {
        final fieldname = entry.key;
        final childInfo = entry.value;
        final childTable = normalizeDoctypeTableName(childInfo.doctype);
        final list = (r[fieldname] as List?) ?? const [];

        batch.delete(
          childTable,
          where: 'parent_uuid = ? AND parentfield = ?',
          whereArgs: [uuid, fieldname],
        );

        for (var idx = 0; idx < list.length; idx++) {
          final cr = Map<String, dynamic>.from(list[idx] as Map);
          final serverChildName = cr['name'] as String?;
          final rawChildUuid = cr['mobile_uuid']?.toString();
          final hasRawUuid = rawChildUuid != null && rawChildUuid.isNotEmpty;
          final childUuid = hasRawUuid ? rawChildUuid : uuidGen.v4();

          final childRow = <String, Object?>{
            'mobile_uuid': childUuid,
            'server_name': serverChildName,
            'parent_uuid': uuid,
            'parent_doctype': parentMeta.name,
            'parentfield': fieldname,
            'idx': idx,
            'modified': cr['modified'] as String?,
          };

          for (final cf in childInfo.meta.fields) {
            final cn = cf.fieldname;
            final ct = cf.fieldtype;
            if (cn == null) continue;
            if (sqliteColumnTypeFor(ct) == null) continue;
            if (_systemChildColumnNames.contains(cn)) continue;
            childRow[cn] = cr[cn];
            if (isLinkFieldType(ct)) {
              childRow['${cn}__is_local'] = 0;
            }
          }
          batch.insert(childTable, childRow);
        }
      }
    }

    await batch.commit(noResult: true);
  }
}
