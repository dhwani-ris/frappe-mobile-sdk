import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../database/field_type_mapping.dart';
import '../database/normalize_for_search.dart';
import '../database/schema/system_columns.dart';
import '../database/sqlite_utils.dart';
import '../database/daos/pending_attachment_dao.dart';
import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';
import '../sync/child_table_info.dart';
import '../utils/media_store.dart';
import '../utils/attachment_paths.dart';
import '../utils/sdk_log.dart';

/// Docfield types whose value is a single file reference that the offline
/// producer must copy + queue for upload.
const Set<String> kAttachmentFieldTypes = {'Attach', 'Attach Image', 'Image'};

/// Writes a form-save payload to the per-doctype `docs__<doctype>` parent
/// table and `docs__<child_doctype>` child tables in a single transaction.
///
/// `docs__<doctype>` is the source of truth for offline reads
/// ([UnifiedResolver]) and writes (push) post-retirement. Used by
/// [OfflineRepository.saveDocument] for offline saves and by
/// [OfflineRepository.applyServerDocument] for pulled rows.
///
/// `mobile_uuid` is the parent PK; [markSynced] reconciles `server_name`
/// onto the same row after a successful push.
class LocalWriter {
  final Database _db;
  final MetaResolverFn _metaResolver;
  final Uuid _uuid;

  /// Returns the authenticated Frappe user id (`SessionUser.name`), or null
  /// when nobody is logged in. Wired to `SessionUserService.current?.name`
  /// by [FrappeSDK]; a plain callback rather than a service reference so this
  /// writer keeps no dependency on the session layer and tests can stub it
  /// with a one-liner.
  ///
  /// OPTIONAL and null by default: [OfflineRepository] and [LocalWriter] are
  /// constructed by host apps and by `FrappeSDK.forTesting`, so a required
  /// parameter would be a breaking change. When it is absent — or returns
  /// null/empty — [writeParentInTxn] behaves exactly as it did before the
  /// audit-field prediction existed: `owner` / `creation` / `modified_by` come
  /// from `data` alone and a device-created doc leaves all three NULL.
  final String? Function()? _currentUserIdFn;

  LocalWriter(
    this._db,
    this._metaResolver, {
    Uuid? uuid,
    String? Function()? currentUserId,
  }) : _uuid = uuid ?? const Uuid(),
       _currentUserIdFn = currentUserId;

  static const _systemParentColumns = systemParentColumnNames;
  static const _systemChildColumns = systemChildColumnNames;

  /// The user id this writer will stamp into `owner` / `modified_by`, or null
  /// when no accessor was injected, nobody is logged in, or the accessor
  /// yields a blank string.
  ///
  /// Public so [OfflineRepository.saveDocument] can tell whether the writer
  /// is going to stamp `modified_by` itself (in which case the repository must
  /// NOT carry the on-disk value forward, or the edit would keep the previous
  /// modifier) without needing its own copy of the accessor.
  ///
  /// A host-supplied closure that throws must not fail the save — the audit
  /// prediction is a convenience, not the payload — so a throw is logged and
  /// treated as "no session user".
  String? get currentSessionUserId {
    final fn = _currentUserIdFn;
    if (fn == null) return null;
    String? raw;
    try {
      raw = fn();
    } catch (e, st) {
      sdkLog('LocalWriter.currentSessionUserId: accessor threw — $e\n$st');
      return null;
    }
    if (raw == null) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Formats [dt] the way Frappe serialises a `Datetime` column:
  /// `YYYY-MM-DD HH:MM:SS` — space separator, no `T`, no timezone designator.
  ///
  /// The format MUST match what the server sends, because `creation` is stored
  /// as TEXT and `FilterParser` compares/orders it with plain SQL operators.
  /// An ISO-8601 string would sort AFTER every server value on the same date
  /// (`' '` < `'T'`) and silently break `creation >= ...` range filters.
  /// Second precision is a lexicographic prefix of Frappe's `.ffffff`. That
  /// makes a bare second-precision string order correctly for `>=` / `>`, but
  /// it is strictly LESS THAN any same-second microsecond value, so it does
  /// NOT hold for `<=` / `<` / `=`:
  ///
  ///     '2026-07-29 23:59:59.123456' <= '2026-07-29 23:59:59'  -> false
  ///     '2026-07-29 12:00:00.000000' =  '2026-07-29 12:00:00'  -> false
  ///
  /// Consequence (pre-existing, not introduced here): the `23:59:59` upper
  /// bounds in `FrappeTimespan._endOfDay` and
  /// `FilterParser._normalizeBetweenBound` exclude server rows created inside
  /// that final second. Fixing that means widening those bounds to
  /// `.999999` or making the upper bound exclusive — a behaviour change, so it
  /// is deliberately not done here.
  ///
  /// KNOWN DISCREPANCY — TIMEZONE BASIS. Callers pass `DateTime.now().toUtc()`,
  /// so a locally-predicted `creation` is in **UTC**. Frappe's `now()` returns
  /// the **site timezone**, and that is what lands in `creation` on pull and on
  /// push writeback. On an IST site (+5:30) a document created offline at 02:00
  /// is stamped `…T20:30` the previous day until the server's value replaces it,
  /// so the row can visibly move between days on sync and a `timespan: "today"`
  /// filter can exclude it before and include it after.
  ///
  /// Not corrected here because the fix needs the site's offset and the server
  /// does not expose one: `frappe-mobile-control` returns no `time_zone` in any
  /// login, permissions, or config payload, so there is nothing to carry. Doing
  /// it properly requires a server change first.
  ///
  /// What IS guaranteed meanwhile is internal consistency: `FrappeTimespan`
  /// (`_defaultNow`, `_startOfDay`, `_endOfDay`) uses the same UTC basis, so the
  /// two SDK-local formatters always agree with each other. Both differ from
  /// server-supplied values in the same column by the site's offset. A host on a
  /// non-UTC site that needs exact parity should treat locally-created rows as
  /// provisional until their first writeback.
  ///
  /// Same shape as `FrappeTimespan._iso`. NOTE: that helper builds bounds for
  /// LOCAL SQLite comparison only — `FilterParser` is pure and does no I/O —
  /// so neither formatter is ever sent to Frappe.
  static String _frappeDateTime(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-'
      '${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:'
      '${dt.minute.toString().padLeft(2, '0')}:'
      '${dt.second.toString().padLeft(2, '0')}';

  /// Convenience: opens a single-shot transaction and delegates to
  /// [writeParentInTxn]. Pre-resolves the parent + child metas BEFORE
  /// opening the txn so the resolver — which typically queries the
  /// `doctype_meta` table through the outer Database — does not deadlock
  /// against the in-flight write txn (sqflite serializes outer reads
  /// behind the txn). Returns the parent's `mobile_uuid`.
  Future<String> writeParent({
    required String parentDoctype,
    required Map<String, dynamic> data,
    String? serverName,
    String? syncOp,
    String? pushBasePayload,
  }) async {
    final rawUuid = data['mobile_uuid'] as String?;
    final mobileUuid = (rawUuid != null && rawUuid.isNotEmpty)
        ? rawUuid
        : _uuid.v4();

    // Pre-resolve metas outside the txn (deadlock guard).
    final parentMeta = await _metaResolver(parentDoctype);
    final childMetasByDoctype = <String, DocTypeMeta>{};
    for (final f in parentMeta.fields) {
      final opt = f.options;
      if ((f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect') &&
          opt != null &&
          opt.isNotEmpty) {
        try {
          childMetasByDoctype[opt] = await _metaResolver(opt);
        } catch (e, st) {
          sdkLog(
            'LocalWriter.writeParent: child meta pre-resolve failed for '
            '$opt — $e\n$st',
          );
        }
      }
    }

    await _db.transaction((txn) async {
      await writeParentInTxn(
        txn: txn,
        parentDoctype: parentDoctype,
        mobileUuid: mobileUuid,
        data: data,
        serverName: serverName,
        syncOp: syncOp,
        pushBasePayload: pushBasePayload,
        parentMeta: parentMeta,
        childMetasByDoctype: childMetasByDoctype,
      );
    });
    return mobileUuid;
  }

  /// Writes (or replaces) a parent document + its child rows into the
  /// per-doctype tables, inside a caller-supplied [Transaction], so the
  /// parent + child writes can be part of a wider spanning txn (e.g. the
  /// `OfflineRepository.saveDocument` save which also enqueues an outbox
  /// row in the same atomic unit).
  ///
  /// [data] is the form payload. `Table` / `Table MultiSelect` fields are
  /// split out into the child doctype's own table.
  ///
  /// `data['mobile_uuid']` becomes the parent PK so a later push can
  /// reconcile `server_name` onto the same row.
  ///
  /// [serverName] — when non-null (server-first save returned a name),
  /// `server_name` is populated and `sync_status='synced'`. Otherwise
  /// `sync_status='dirty'`.
  ///
  /// Silently no-ops if the parent table doesn't exist yet (initial sync
  /// hasn't run).
  ///
  /// [parentMeta] is REQUIRED and [childMetasByDoctype] SHOULD hold every
  /// child doctype's meta — both MUST be pre-resolved by the caller OUTSIDE
  /// this txn. Meta is never resolved here: [_metaResolver] queries
  /// `doctype_meta` through the outer Database, which would hang on the
  /// sqflite write queue if invoked while this txn holds it. Child doctypes
  /// absent from [childMetasByDoctype] are skipped (rows not written).
  Future<void> writeParentInTxn({
    required Transaction txn,
    required String parentDoctype,
    required String mobileUuid,
    required Map<String, dynamic> data,
    String? serverName,
    String? syncOp,
    String? pushBasePayload,
    required DocTypeMeta parentMeta,
    Map<String, DocTypeMeta>? childMetasByDoctype,
  }) async {
    // [parentMeta] / [childMetasByDoctype] are pre-resolved by the caller
    // (see doc above). NEVER resolve meta in-txn: querying the outer
    // Database while this txn holds the sqflite write queue hangs forever
    // on the non-reentrant lock (a Dart deadlock, not SQLITE_BUSY).
    final parentTable = normalizeDoctypeTableName(parentDoctype);
    if (!await sqliteTableExists(txn, parentTable)) return;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

    // Offline attachment producer: any attach-field value that is still a
    // local file path is copied-at-pick already, so here we only queue it
    // (with its exact parent/child coordinates) and replace the stored value
    // with a `pending:<id>` marker the push pipeline resolves to a file_url.
    final attachDao = PendingAttachmentDao(txn);
    Future<Object?> queueIfLocalAttachment({
      required Object? value,
      required String fieldType,
      required String rowUuid,
      required String rowDoctype,
      required String fieldname,
    }) async {
      if (!kAttachmentFieldTypes.contains(fieldType)) return value;

      // A CLEARED attach field (discarded by the user) must drop its queued
      // row and staged file. Without this the row survives with the column
      // emptied, and the push gate then blocks the document forever on an
      // attachment nothing references — or, if it uploads, the writeback
      // resurrects the url the user just removed.
      //
      // Scoped to null/empty ONLY, not "anything that is not a local path": a
      // synced field holds `/files/...` and its `done` row is the writeback
      // backstop, so widening this would delete that row on every unrelated
      // re-save for no benefit.
      final isCleared =
          value == null || (value is String && value.trim().isEmpty);
      if (isCleared) {
        await _dropQueuedAttachment(txn, rowUuid, fieldname);
        return value;
      }

      if (!isLocalAttachmentPath(value)) return value;
      final path = (value as String).trim();
      // Idempotency: the (parent_uuid, parent_fieldname) index is not UNIQUE,
      // so a re-pick/re-save would otherwise stack duplicate rows. Drop any
      // prior queue row for this exact field — AND its staged file, or the
      // bytes leak with nothing left referencing them.
      //
      // This is also how a `rejected` attachment is replaced: the old row is
      // destroyed and a fresh `pending` one takes its place, so it never
      // inherits a stale retry count or error. A rejected row is never
      // resurrected in place.
      // `keepPath` matters: a re-save that re-supplies the SAME staged path
      // must not delete the file it is about to queue.
      await _dropQueuedAttachment(txn, rowUuid, fieldname, keepPath: path);
      // Size and MIME are derived HERE rather than carried from the pick:
      // the staged file is on disk and its path is the field value, so there is
      // nothing to plumb through the form. `fileName` is the staged basename,
      // which IS the user's original filename — staging keeps the name and puts
      // uniqueness in the parent directory.
      int? sizeBytes;
      try {
        sizeBytes = await File(path).length();
      } catch (e, st) {
        sdkLog('LocalWriter: could not stat staged attachment $path — $e\n$st');
      }
      final id = await attachDao.enqueue(
        parentDoctype: rowDoctype,
        parentUuid: rowUuid,
        parentFieldname: fieldname,
        topParentUuid: mobileUuid,
        topParentDoctype: parentDoctype,
        localPath: path,
        fileName: path.split('/').last,
        mimeType: mimeTypeForPath(path),
        sizeBytes: sizeBytes,
      );
      return '$kPendingMarkerPrefix$id';
    }

    final childInfos = <String, ChildTableInfo>{};
    for (final f in parentMeta.fields) {
      final ft = f.fieldtype;
      final fn = f.fieldname;
      final opt = f.options;
      if ((ft == 'Table' || ft == 'Table MultiSelect') &&
          fn != null &&
          opt != null &&
          opt.isNotEmpty) {
        final cm = childMetasByDoctype?[opt];
        if (cm == null) {
          // Caller omitted this child's meta (not synced) — skip its rows.
          // Resolving here would hang on the sqflite write queue (see above).
          sdkLog(
            'LocalWriter.writeParentInTxn: child meta not supplied for '
            '$opt — skipping child rows',
          );
          continue;
        }
        childInfos[fn] = ChildTableInfo(opt, cm);
      }
    }

    final normFields = parentMeta.normFieldNames;

    final audit = await _resolveParentAudit(
      txn: txn,
      parentTable: parentTable,
      mobileUuid: mobileUuid,
      data: data,
      serverName: serverName,
    );

    final parentRow = <String, Object?>{
      'mobile_uuid': mobileUuid,
      'server_name': serverName,
      'sync_status': syncOp != null
          ? 'dirty'
          : (serverName != null ? 'synced' : 'dirty'),
      'sync_op': ?syncOp,
      'docstatus': _coerceInt(data['docstatus']) ?? 0,
      'modified': data['modified']?.toString(),
      // Frappe's audit fields — see [_resolveParentAudit]. Always emitted
      // explicitly because the insert below is `ConflictAlgorithm.replace`:
      // an omitted column is reset to NULL, which would erase whatever a
      // previous pull (or an earlier local save) stored for this row.
      'owner': audit.owner,
      'creation': audit.creation,
      'modified_by': audit.modifiedBy,
      'local_modified': nowMs,
      'push_base_payload': ?pushBasePayload,
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

      var v = _coerce(data[name], sqlType);
      v = await queueIfLocalAttachment(
        value: v,
        fieldType: type,
        rowUuid: mobileUuid,
        rowDoctype: parentDoctype,
        fieldname: name,
      );
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
      if (!await sqliteTableExists(txn, childTable)) continue;

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
        final rawChildUuid = cr['mobile_uuid'] as String?;
        final childUuid = (rawChildUuid != null && rawChildUuid.isNotEmpty)
            ? rawChildUuid
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

          var v = _coerce(cr[cn], cSqlType);
          v = await queueIfLocalAttachment(
            value: v,
            fieldType: ct,
            rowUuid: childUuid,
            rowDoctype: childInfo.doctype,
            fieldname: cn,
          );
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
  }

  /// Resolves Frappe's audit trio for a PARENT row. PARENT ONLY — child
  /// mirror tables carry none of these columns (`child_schema.dart` never
  /// emits them), so the child-row block above must never call this.
  ///
  /// Precedence, highest first:
  ///
  /// 1. **[data]** — a value the caller supplied. This is how server truth
  ///    reaches the mirror through this writer, so it always wins over a
  ///    local prediction. (The pull path and the push response writeback do
  ///    not go through here at all; they UPDATE the row directly and
  ///    unconditionally overwrite whatever was predicted.)
  /// 2. **the row already on disk** — so EDITING a document keeps its
  ///    original `owner` and `creation` instant. Consulted inside [txn] via
  ///    `SELECT *`, never a column list: a `docs__*` table provisioned
  ///    outside `_migrateV5ToV6` / `reconcileParentTableForMeta` may still
  ///    lack the columns, and an explicit list would throw `no such column`.
  /// 3. **a local prediction** — only for a document that ORIGINATES ON THIS
  ///    DEVICE (`server_name` null here AND on disk).
  ///
  /// Predicting is not fabrication: Frappe assigns `owner` to the
  /// authenticated user performing the insert, so the local value is a
  /// correct forecast the server later confirms — the same thing Frappe's own
  /// web client does in `frappe.model.get_new_doc`. Leaving `owner` NULL is
  /// what actually broke: `FilterParser` now emits real SQL for these
  /// columns, so an `owner = <me>` list silently omitted the user's own
  /// offline-created record until it synced AND the server value was written
  /// back — the record looked lost.
  ///
  /// `modified_by` is the one field a local save legitimately MOVES: the
  /// session user performing this write is who Frappe will record on push.
  ///
  /// With no session user (no accessor injected, logged out, or a blank id)
  /// this is a pure passthrough of [data] — identical to the behaviour before
  /// prediction existed, and it issues no extra query.
  Future<({String? owner, String? creation, String? modifiedBy})>
  _resolveParentAudit({
    required Transaction txn,
    required String parentTable,
    required String mobileUuid,
    required Map<String, dynamic> data,
    required String? serverName,
  }) async {
    var owner = data['owner']?.toString();
    var creation = data['creation']?.toString();

    final me = currentSessionUserId;
    if (me == null) {
      return (
        owner: owner,
        creation: creation,
        modifiedBy: data['modified_by']?.toString(),
      );
    }

    final modifiedBy = data['modified_by']?.toString() ?? me;
    if (owner != null && creation != null) {
      return (owner: owner, creation: creation, modifiedBy: modifiedBy);
    }

    Map<String, Object?>? prior;
    try {
      final rows = await txn.query(
        parentTable,
        where: 'mobile_uuid = ?',
        whereArgs: [mobileUuid],
        limit: 1,
      );
      prior = rows.isEmpty ? null : rows.first;
    } catch (e, st) {
      // Never fail the save over an audit prediction — fall through and
      // predict as if this were a fresh row.
      sdkLog(
        'LocalWriter._resolveParentAudit: prior-row probe failed for '
        '$parentTable/$mobileUuid — $e\n$st',
      );
      prior = null;
    }

    owner ??= prior?['owner']?.toString();
    creation ??= prior?['creation']?.toString();

    // A server-known row's `owner` belongs to whoever created it there —
    // possibly not this user — so never invent one for it.
    final serverKnown = serverName != null || prior?['server_name'] != null;
    if (!serverKnown) {
      owner ??= me;
      creation ??= _frappeDateTime(DateTime.now().toUtc());
    }

    return (owner: owner, creation: creation, modifiedBy: modifiedBy);
  }

  /// Updates `server_name` + `sync_status='synced'` on the parent row
  /// after push sync confirms the doc landed on the server. Called by
  /// [ResponseWriteback] on a successful push response.
  Future<void> markSynced({
    required String parentDoctype,
    required String mobileUuid,
    required String serverName,
  }) async {
    final parentTable = normalizeDoctypeTableName(parentDoctype);
    await _db.transaction((txn) async {
      if (!await sqliteTableExists(txn, parentTable)) return;
      await txn.update(
        parentTable,
        <String, Object?>{'server_name': serverName, 'sync_status': 'synced'},
        where: 'mobile_uuid = ?',
        whereArgs: [mobileUuid],
      );
    });
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

/// Deletes any queued attachment row for `(rowUuid, fieldname)` and its staged
/// file.
///
/// Shared by the re-pick path (which replaces the row) and the discard path
/// (which removes it outright). [keepPath] spares one path so a re-save that
/// re-supplies the same staged file does not delete the bytes it is about to
/// queue.
Future<void> _dropQueuedAttachment(
  Transaction txn,
  String rowUuid,
  String fieldname, {
  String? keepPath,
}) async {
  final priorRows = await txn.query(
    'pending_attachments',
    columns: ['local_path'],
    where: 'parent_uuid = ? AND parent_fieldname = ?',
    whereArgs: [rowUuid, fieldname],
  );
  if (priorRows.isEmpty) return;
  await txn.delete(
    'pending_attachments',
    where: 'parent_uuid = ? AND parent_fieldname = ?',
    whereArgs: [rowUuid, fieldname],
  );
  for (final r in priorRows) {
    final prior = r['local_path'] as String?;
    if (prior != null && prior.isNotEmpty && prior != keepPath) {
      await MediaStore.deleteOutboxCopy(prior);
    }
  }
}
