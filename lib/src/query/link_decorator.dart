import 'package:sqflite/sqflite.dart';

import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';

/// Resolves the [DocTypeMeta] for the target of a Link / Dynamic Link
/// during decoration. Same signature as [MetaResolverFn] — kept as an
/// alias so the [LinkDecorator] API has a self-explanatory name.
typedef TargetMetaResolver = MetaResolverFn;

/// Adds a `<field>__display` companion to every Link / Dynamic Link
/// value in [row] so the UI can show the target's title without an extra
/// fetch. Spec §6.2 step 3.
///
/// Resolution rules per field:
/// - `__is_local=1`: the value is a `mobile_uuid` for a doc that hasn't
///   been pushed yet → look up the target by `mobile_uuid`.
/// - `__is_local=0` (or absent): the value is a server `name` → look up
///   the target by `server_name`.
///
/// On miss (target row not in local DB), the raw value is returned as
/// the display value — caller renders it as-is and a future pull will
/// hydrate the target.
class LinkDecorator {
  static Future<Map<String, Object?>> decorate({
    required Database db,
    required DocTypeMeta parentMeta,
    required Map<String, Object?> row,
    required TargetMetaResolver targetMetaResolver,
  }) async {
    final out = Map<String, Object?>.from(row);
    for (final f in parentMeta.fields) {
      if (f.fieldtype != 'Link' && f.fieldtype != 'Dynamic Link') continue;
      final name = f.fieldname;
      if (name == null || name.isEmpty) continue;
      final v = row[name];
      if (v == null) continue;

      String? targetDoctype;
      if (f.fieldtype == 'Link') {
        targetDoctype = f.options;
      } else {
        // Dynamic Link: `options` names a sibling field that holds the doctype.
        final sibling = f.options;
        if (sibling != null && sibling.isNotEmpty) {
          targetDoctype = row[sibling] as String?;
        }
      }
      if (targetDoctype == null || targetDoctype.isEmpty) {
        out['${name}__display'] = v;
        continue;
      }

      final isLocal = (row['${name}__is_local'] as int?) == 1;
      final targetTable = normalizeDoctypeTableName(targetDoctype);
      final targetMeta = await targetMetaResolver(targetDoctype);
      final titleCol = targetMeta.titleField ?? 'server_name';

      final List<Map<String, Object?>> targetRows;
      try {
        targetRows = await db.query(
          targetTable,
          columns: [titleCol, 'server_name'],
          where: isLocal ? 'mobile_uuid = ?' : 'server_name = ?',
          whereArgs: [v],
          limit: 1,
        );
      } on DatabaseException {
        // Target table not yet provisioned (closure may not have reached
        // it). Fall back to raw value — UI shows the UUID/name as-is.
        out['${name}__display'] = v;
        continue;
      }
      if (targetRows.isEmpty) {
        out['${name}__display'] = v;
      } else {
        final title = targetRows.first[titleCol];
        out['${name}__display'] =
            title ?? targetRows.first['server_name'] ?? v;
      }
    }
    return out;
  }
}
