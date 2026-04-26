import 'package:sqflite/sqflite.dart';

import '../models/doc_type_meta.dart';
import '../models/outbox_row.dart';
import 'uuid_rewriter.dart';

/// Per-child-doctype info passed to [PayloadAssembler.assemble].
abstract class ChildInfo {
  String get doctype;
  DocTypeMeta get meta;
  String get tableName;
}

const _systemColumns = <String>{
  'mobile_uuid',
  'server_name',
  'sync_status',
  'sync_error',
  'sync_attempts',
  'sync_op',
  'local_modified',
  'pulled_at',
  // `modified` is handled explicitly: included for UPDATE/SUBMIT (Frappe's
  // check_if_latest), excluded for INSERT.
};

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
    final parent = (await db.query(
      parentTable,
      where: 'mobile_uuid = ?',
      whereArgs: [row.mobileUuid],
      limit: 1,
    ))
        .first;

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
        for (final e in c.entries) {
          if (_systemColumns.contains(e.key)) continue;
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
