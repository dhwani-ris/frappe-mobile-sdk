import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/field_type_mapping.dart';
import '../database/normalize_for_search.dart';
import '../database/schema_applier.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';

/// Writes a form-save payload to the per-doctype `docs__<doctype>` parent
/// table and `docs__<child_doctype>` child tables in a single transaction.
///
/// Called alongside the legacy `OfflineRepository.createDocument` so the
/// new offline-first read path ([UnifiedResolver]) sees newly-saved data
/// — fixes the case where Link pickers on other forms cannot find
/// offline-created child rows that live only in the legacy `documents`
/// JSON blob.
///
/// The same `mobile_uuid` is used in both stores so [markSynced] can
/// reconcile `server_name` after push sync completes.
class LocalWriter {
  final Database _db;
  final MetaResolverFn _metaResolver;
  final Uuid _uuid;

  LocalWriter(this._db, this._metaResolver, {Uuid? uuid})
      : _uuid = uuid ?? const Uuid();

  static const _systemParentColumns = <String>{
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

  static const _systemChildColumns = <String>{
    'mobile_uuid',
    'server_name',
    'parent_uuid',
    'parent_doctype',
    'parentfield',
    'idx',
    'modified',
  };

  /// Writes (or replaces) a parent document + its child rows into the
  /// per-doctype tables. Returns the parent's `mobile_uuid`.
  ///
  /// [data] is the form payload. `Table` / `Table MultiSelect` fields are
  /// split out into the child doctype's own table.
  ///
  /// If `data['mobile_uuid']` is set, it's used as the parent PK so the
  /// row aligns with the legacy `documents` row's mobile_uuid for later
  /// server-name reconciliation. Otherwise a new UUID is generated.
  ///
  /// [serverName] — when non-null (server-first save returned a name),
  /// `server_name` is populated and `sync_status='synced'`. Otherwise
  /// `sync_status='dirty'`.
  ///
  /// Silently no-ops if the parent table doesn't exist yet (initial sync
  /// hasn't run). The legacy write path still records the doc, so no data
  /// is lost.
  Future<String> writeParent({
    required String parentDoctype,
    required Map<String, dynamic> data,
    String? serverName,
  }) async {
    final parentMeta = await _metaResolver(parentDoctype);
    final parentTable = normalizeDoctypeTableName(parentDoctype);
    final _rawUuid = data['mobile_uuid'] as String?;
    final mobileUuid =
        (_rawUuid != null && _rawUuid.isNotEmpty) ? _rawUuid : _uuid.v4();
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

    final childInfos = <String, _ChildInfo>{};
    for (final f in parentMeta.fields) {
      final ft = f.fieldtype;
      final fn = f.fieldname;
      final opt = f.options;
      if ((ft == 'Table' || ft == 'Table MultiSelect') &&
          fn != null && opt != null && opt.isNotEmpty) {
        try {
          final cm = await _metaResolver(opt);
          childInfos[fn] = _ChildInfo(opt, cm);
        } catch (_) {
          // Child meta unavailable — skip splitting; legacy table still
          // holds the nested array, so the data isn't lost.
        }
      }
    }

    final normFields = <String>{};
    if (parentMeta.titleField != null) normFields.add(parentMeta.titleField!);
    for (final sf in (parentMeta.searchFields ?? const <String>[])) {
      normFields.add(sf);
    }

    await _db.transaction((txn) async {
      if (!await _tableExists(txn, parentTable)) return;

      final parentRow = <String, Object?>{
        'mobile_uuid': mobileUuid,
        'server_name': serverName,
        'sync_status': serverName != null ? 'synced' : 'dirty',
        'docstatus': _coerceInt(data['docstatus']) ?? 0,
        'modified': data['modified']?.toString(),
        'local_modified': nowMs,
      };

      for (final f in parentMeta.fields) {
        final name = f.fieldname;
        final type = f.fieldtype;
        if (name == null) continue;
        if (type == 'Table' || type == 'Table MultiSelect') continue;
        final sqlType = sqliteColumnTypeFor(type);
        if (sqlType == null) continue;
        if (_systemParentColumns.contains(name)) continue;
        if (!data.containsKey(name)) continue;

        final v = _coerce(data[name], sqlType);
        parentRow[name] = v;

        if (isLinkFieldType(type)) {
          // Default to server-known. When the form picker selects a
          // local-only target row, the caller is expected to pass
          // `<field>__is_local: 1` in `data` directly (handled below).
          parentRow['${name}__is_local'] =
              _coerceInt(data['${name}__is_local']) ?? 0;
        }
        if (normFields.contains(name) && sqlType == 'TEXT') {
          parentRow['${name}__norm'] = normalizeForSearch(v?.toString());
        }
      }

      await txn.insert(
        parentTable,
        parentRow,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final entry in childInfos.entries) {
        final fieldname = entry.key;
        final childInfo = entry.value;
        final childTable = normalizeDoctypeTableName(childInfo.doctype);
        if (!await _tableExists(txn, childTable)) continue;

        await txn.delete(
          childTable,
          where: 'parent_uuid = ? AND parentfield = ?',
          whereArgs: [mobileUuid, fieldname],
        );

        final list = data[fieldname];
        if (list is! List) continue;

        for (var idx = 0; idx < list.length; idx++) {
          final raw = list[idx];
          if (raw is! Map) continue;
          final cr = Map<String, dynamic>.from(raw);
          final _rawChildUuid = cr['mobile_uuid'] as String?;
          final childUuid =
              (_rawChildUuid != null && _rawChildUuid.isNotEmpty)
                  ? _rawChildUuid
                  : _uuid.v4();
          final childServerName = cr['name']?.toString();

          final childRow = <String, Object?>{
            'mobile_uuid': childUuid,
            'server_name': childServerName,
            'parent_uuid': mobileUuid,
            'parent_doctype': parentDoctype,
            'parentfield': fieldname,
            'idx': idx,
            'modified': cr['modified']?.toString(),
          };

          for (final cf in childInfo.meta.fields) {
            final cn = cf.fieldname;
            final ct = cf.fieldtype;
            if (cn == null) continue;
            if (ct == 'Table' || ct == 'Table MultiSelect') continue;
            final cSqlType = sqliteColumnTypeFor(ct);
            if (cSqlType == null) continue;
            if (_systemChildColumns.contains(cn)) continue;
            if (!cr.containsKey(cn)) continue;

            final v = _coerce(cr[cn], cSqlType);
            childRow[cn] = v;
            if (isLinkFieldType(ct)) {
              childRow['${cn}__is_local'] =
                  _coerceInt(cr['${cn}__is_local']) ?? 0;
            }
          }

          await txn.insert(
            childTable,
            childRow,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });

    return mobileUuid;
  }

  /// Updates `server_name` + `sync_status='synced'` on the parent row
  /// after push sync confirms the doc landed on the server. Call this
  /// from the same site that calls `OfflineRepository.saveServerDocument`.
  Future<void> markSynced({
    required String parentDoctype,
    required String mobileUuid,
    required String serverName,
  }) async {
    final parentTable = normalizeDoctypeTableName(parentDoctype);
    await _db.transaction((txn) async {
      if (!await _tableExists(txn, parentTable)) return;
      await txn.update(
        parentTable,
        <String, Object?>{
          'server_name': serverName,
          'sync_status': 'synced',
        },
        where: 'mobile_uuid = ?',
        whereArgs: [mobileUuid],
      );
    });
  }

  Future<bool> _tableExists(DatabaseExecutor txn, String name) async {
    final rows = await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [name],
    );
    return rows.isNotEmpty;
  }

  Object? _coerce(Object? v, String sqlType) {
    if (v == null) return null;
    if (sqlType == 'TEXT') {
      if (v is String) return v;
      return v.toString();
    }
    if (sqlType == 'INTEGER') return _coerceInt(v);
    if (sqlType == 'REAL') {
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString().trim());
    }
    return v;
  }

  int? _coerceInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v.toInt();
    final s = v.toString().trim();
    if (s.isEmpty) return null;
    return int.tryParse(s);
  }
}

class _ChildInfo {
  final String doctype;
  final DocTypeMeta meta;
  _ChildInfo(this.doctype, this.meta);
}
