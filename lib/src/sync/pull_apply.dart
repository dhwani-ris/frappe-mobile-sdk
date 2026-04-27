import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/field_type_mapping.dart';
import '../database/normalize_for_search.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';

/// System columns that the per-doctype mirror manages itself. A meta field
/// that shares one of these names (e.g. `mobile_uuid` exposed for L2
/// idempotency, or Frappe's stock `modified` / `docstatus`) must not be
/// allowed to overwrite the system-set value during the meta loop --
/// `mobile_uuid` is the local PK and would PK-collide on the next empty
/// string the server returns. Mirrors the same set in
/// `database/schema/parent_schema.dart`.
const _systemParentColumnNames = <String>{
  'mobile_uuid',
  'server_name',
  'sync_status',
  'sync_error',
  'sync_attempts',
  'sync_op',
  'docstatus',
  'modified',
  'local_modified',
  'pulled_at',
};

/// System columns the child mirror manages itself. Same rationale.
/// Mirrors `database/schema/child_schema.dart`.
const _systemChildColumnNames = <String>{
  'mobile_uuid',
  'server_name',
  'parent_uuid',
  'parent_doctype',
  'parentfield',
  'idx',
  'modified',
};

class PullApplyChildInfo {
  final String doctype;
  final DocTypeMeta meta;

  PullApplyChildInfo(this.doctype, this.meta);
}

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
  }) async {
    await db.transaction((txn) async {
      await applyPageInTxn(
        txn: txn,
        parentMeta: parentMeta,
        parentTable: parentTable,
        childMetasByFieldname: childMetasByFieldname,
        rows: rows,
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
  }) async {
    final uuidGen = const Uuid();
    final parentNormFields = _normFieldNames(parentMeta);

    for (final r in rows) {
      final serverName = r['name'] as String?;
      if (serverName == null) continue;

      final existing = await txn.query(
        parentTable,
        columns: ['mobile_uuid', 'sync_status', 'modified'],
        where: 'server_name = ?',
        whereArgs: [serverName],
        limit: 1,
      );

      if (existing.isNotEmpty &&
          const ['dirty', 'failed', 'conflict']
              .contains(existing.first['sync_status'])) {
        // Spec §5.1 requires "server has advanced" before flagging a
        // conflict. Cursor filtering normally guarantees this, but
        // defending here prevents spurious conflicts on initial sync,
        // cursor reset, and look-ahead pages where a row may resurface
        // with the same `modified` we already hold.
        final storedModified = DateTime.tryParse(
          (existing.first['modified'] as String?) ?? '',
        );
        final incomingModified = DateTime.tryParse(
          (r['modified'] as String?) ?? '',
        );
        final serverAdvanced = incomingModified != null &&
            (storedModified == null ||
                incomingModified.isAfter(storedModified));
        if (serverAdvanced) {
          await txn.update(
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
        await txn.insert(parentTable, parentRow);
      } else {
        await txn.update(
          parentTable,
          parentRow,
          where: 'mobile_uuid = ?',
          whereArgs: [uuid],
        );
      }

      for (final entry in childMetasByFieldname.entries) {
        final fieldname = entry.key;
        final childInfo = entry.value;
        final childTable = normalizeDoctypeTableName(childInfo.doctype);
        final list = (r[fieldname] as List?) ?? const [];

        await txn.delete(
          childTable,
          where: 'parent_uuid = ? AND parentfield = ?',
          whereArgs: [uuid, fieldname],
        );

        for (var idx = 0; idx < list.length; idx++) {
          final cr = Map<String, dynamic>.from(list[idx] as Map);
          final childRow = <String, Object?>{
            'mobile_uuid': uuidGen.v4(),
            'server_name': cr['name'] as String?,
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
          await txn.insert(childTable, childRow);
        }
      }
    }
  }

  static Set<String> _normFieldNames(DocTypeMeta meta) {
    final out = <String>{};
    if (meta.titleField != null) out.add(meta.titleField!);
    for (final sf in (meta.searchFields ?? const <String>[])) {
      out.add(sf);
    }
    return out;
  }
}
