import 'package:sqflite/sqflite.dart';

import '../database/schema/system_columns.dart';
import '../models/doc_type_meta.dart';
import '../models/outbox_row.dart';
import 'child_table_info.dart';
import 'push_error.dart';
import 'uuid_rewriter.dart';

/// Back-compat alias for [ChildTableInfo]. Retained so push-side code
/// keeps reading `ChildInfo` without churn while the three older copies
/// of the struct collapse onto the canonical class.
typedef ChildInfo = ChildTableInfo;

// Columns dropped before the assembled payload reaches the wire. Shared
// with [PayloadSerializer] via [systemSyncMetadataColumnNames] so the two
// strip-decisions cannot drift apart. Intentionally NARROWER than
// `PayloadSerializer.serializeForBase` — `__is_local` companion columns
// are kept here so [UuidRewriter] can see which Link values are local
// UUIDs that need rewriting. UuidRewriter strips `__is_local` itself
// before returning. `modified` is handled explicitly: included for
// UPDATE/SUBMIT (Frappe's check_if_latest), excluded for INSERT.
const _systemColumns = systemSyncMetadataColumnNames;

class PayloadAssembler {
  /// Reads the authoritative DB snapshot for [row], builds a payload dict
  /// including the parent's persisted columns + nested children (ordered
  /// by `idx`), and routes it through [UuidRewriter] to substitute any
  /// local Link UUIDs with their server names.
  ///
  /// System columns (sync_*, pulled_at, etc.) are stripped before
  /// returning. The result is ready to send to Frappe.
  static Future<Map<String, Object?>> assemble({
    required Database db,
    required OutboxRow row,
    required DocTypeMeta parentMeta,
    required String parentTable,
    required Map<String, ChildInfo> childMetasByFieldname,
    required ResolveServerNameFn resolveServerName,
  }) async {
    final parentRows = await db.query(
      parentTable,
      where: 'mobile_uuid = ?',
      whereArgs: [row.mobileUuid],
      limit: 1,
    );
    if (parentRows.isEmpty) {
      // The parent row was deleted between outbox-insert and push-run —
      // either by a manual cleanup, a cascading delete, or an aborted
      // create flow. Surface a structured rejection instead of crashing
      // the WriteQueue task with StateError.
      throw ServerRejection(
        status: 0,
        rawBody:
            'Local row missing for outbox entry mobile_uuid=${row.mobileUuid}',
      );
    }
    final parent = parentRows.first;

    final payload = <String, Object?>{
      'doctype': parentMeta.name,
      'mobile_uuid': row.mobileUuid,
    };

    for (final entry in parent.entries) {
      final key = entry.key;
      if (_systemColumns.contains(key)) continue;
      if (key.endsWith('__norm')) continue;
      if (key == 'modified') {
        // Frappe's check_if_latest needs `modified` for UPDATE/SUBMIT/CANCEL.
        if (row.operation == OutboxOperation.update ||
            row.operation == OutboxOperation.submit ||
            row.operation == OutboxOperation.cancel) {
          payload[key] = entry.value;
        }
        continue;
      }
      payload[key] = entry.value;
    }

    final childMetaForRewrite = <String, DocTypeMeta>{};
    for (final entry in childMetasByFieldname.entries) {
      final fieldname = entry.key;
      final info = entry.value;
      childMetaForRewrite[fieldname] = info.meta;
      final children = await db.query(
        info.tableName,
        where: 'parent_uuid = ? AND parentfield = ?',
        whereArgs: [row.mobileUuid, fieldname],
        orderBy: 'idx ASC',
      );
      final cleaned = <Map<String, Object?>>[];
      for (final c in children) {
        final out = <String, Object?>{'doctype': info.doctype};
        // Re-add the child's OWN `mobile_uuid`, mirroring what the parent seed
        // above does. `mobile_uuid` is in `_systemColumns`, so the strip loop
        // below drops it — and for children nothing used to put it back, which
        // meant the server stored child uuids as NULL and a child could not be
        // matched by identity across a round trip. `mobile_control` already
        // provisions the field on child doctypes (UNIQUE, read_only), so the
        // wire was the only missing half; the parent has always sent it under
        // the same `read_only` flag, which is why the server accepts it.
        //
        // Omitted when blank rather than sent as '': the column is UNIQUE, and
        // MariaDB permits many NULLs but not many empty strings, so a blank
        // would fail the second such row. A local child row always has a
        // non-empty uuid (it is that mirror's primary key), so this is a guard
        // against a malformed row, not an expected path.
        //
        // Deliberately the child's own uuid, never `row.mobileUuid`: the parent
        // uuid is already on the payload root, and reusing it here would collide
        // on the server's UNIQUE index as soon as a second child was sent.
        final childUuid = c['mobile_uuid'];
        if (childUuid is String && childUuid.isNotEmpty) {
          out['mobile_uuid'] = childUuid;
        }
        for (final e in c.entries) {
          if (_systemColumns.contains(e.key)) continue;
          if (e.key.endsWith('__norm')) continue;
          if (e.key == 'parent_doctype' || e.key == 'parent_uuid') continue;
          out[e.key] = e.value;
        }
        cleaned.add(out);
      }
      payload[fieldname] = cleaned;
    }

    return UuidRewriter.rewrite(
      meta: parentMeta,
      payload: payload,
      resolveServerName: resolveServerName,
      childMetasByFieldname: childMetaForRewrite,
    );
  }
}
