import '../../models/doc_type_meta.dart';
import '../field_type_mapping.dart';
import 'system_columns.dart';

/// Column names emitted by the child system block. A meta field that uses
/// one of these names (e.g. a doctype that exposes `idx` or `modified` as
/// a regular field) is skipped so SQLite doesn't reject the CREATE TABLE
/// with `duplicate column name`.
const _childSystemColumnNames = systemChildColumnNames;

/// DDL for a child (`istable=1`) doctype's table. Children share parent's
/// sync_status so no sync_* columns here.
List<String> buildChildSchemaDDL(
  DocTypeMeta meta, {
  required String tableName,
}) {
  final cols = <String>[
    'mobile_uuid TEXT PRIMARY KEY',
    'server_name TEXT',
    'parent_uuid TEXT NOT NULL',
    'parent_doctype TEXT NOT NULL',
    'parentfield TEXT NOT NULL',
    'idx INTEGER NOT NULL',
    'modified TEXT',
  ];

  final seen = <String>{..._childSystemColumnNames};
  for (final f in meta.fields) {
    final name = f.fieldname;
    final type = f.fieldtype;
    if (name == null) continue;
    if (!seen.add(name)) continue;
    final sqlType = sqliteColumnTypeFor(type);
    if (sqlType == null) continue;
    cols.add('$name $sqlType');
    if (isLinkFieldType(type)) {
      cols.add('${name}__is_local INTEGER');
    }
  }

  // `IF NOT EXISTS` on every CREATE makes the DDL idempotent so a re-entry
  // after a partial prior failure (or a concurrent caller racing against
  // SNF's `runSnfPostSdkSync.ensureSchemaForClosure`) cannot abort the
  // schema-create loop on "table/index already exists". See parent_schema.dart
  // for the full rationale.
  final suffix = tableName.replaceFirst('docs__', '');
  return [
    'CREATE TABLE IF NOT EXISTS $tableName (\n  ${cols.join(',\n  ')}\n)',
    'CREATE UNIQUE INDEX IF NOT EXISTS ix_${suffix}_server_name '
        'ON $tableName(server_name) WHERE server_name IS NOT NULL',
    'CREATE UNIQUE INDEX IF NOT EXISTS ux_${suffix}_parent_slot '
        'ON $tableName(parent_uuid, parentfield, idx)',
  ];
}
