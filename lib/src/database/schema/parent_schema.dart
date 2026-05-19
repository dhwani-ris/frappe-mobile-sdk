import '../../models/doc_type_meta.dart';
import '../field_type_mapping.dart';
import 'index_policy.dart';
import 'system_columns.dart';

/// Column names emitted by the system block. A meta field that uses one
/// of these names (e.g. a consumer-defined `mobile_uuid` field for L2
/// idempotency, or Frappe's standard `modified` / `docstatus`) is
/// dropped from the meta loop — the system column already covers it,
/// and SQLite refuses duplicate column names in `CREATE TABLE`.
const _systemColumnNames = systemParentColumnNames;

/// Returns the ordered list of DDL statements to create a parent
/// `docs__<doctype>` table + its indexes. Apply in a single transaction.
List<String> buildParentSchemaDDL(
  DocTypeMeta meta, {
  required String tableName,
  int maxIndexes = 7,
  Map<String, int>? linkEdgeCount,
}) {
  final cols = <String>[
    'mobile_uuid TEXT PRIMARY KEY',
    'server_name TEXT',
    "sync_status TEXT NOT NULL DEFAULT 'dirty'",
    'sync_error TEXT',
    'error_code TEXT',
    'sync_attempts INTEGER NOT NULL DEFAULT 0',
    'last_attempt_at INTEGER',
    'sync_op TEXT',
    'push_base_payload TEXT',
    'docstatus INTEGER NOT NULL DEFAULT 0',
    'modified TEXT',
    'local_modified INTEGER NOT NULL',
    'pulled_at INTEGER',
  ];

  final normFields = meta.normFieldNames;
  final seen = <String>{..._systemColumnNames};

  for (final f in meta.fields) {
    final name = f.fieldname;
    final type = f.fieldtype;
    if (name == null) continue;
    if (!seen.add(name)) continue; // skip system + already-emitted dups
    final sqlType = sqliteColumnTypeFor(type);
    if (sqlType == null) continue;

    cols.add('$name $sqlType');

    if (isLinkFieldType(type)) {
      cols.add('${name}__is_local INTEGER');
    }

    if (normFields.contains(name) && sqlType == 'TEXT') {
      cols.add('${name}__norm TEXT');
    }
  }

  // `IF NOT EXISTS` on every CREATE makes the DDL idempotent so a second
  // caller (e.g. SDK's schema-eager `_runUpgradeClosurePull` racing with
  // SNF's `runSnfPostSdkSync.ensureSchemaForClosure`, or a re-entry after
  // a partial prior failure) cannot abort the loop on "table already
  // exists" / "index already exists" and leave later doctypes — especially
  // child tables — uncreated. Aligns with `feedback_migration_safety_pattern`:
  // idempotent CREATEs should be safe to re-run without explicit guards.
  final ddl = <String>[
    'CREATE TABLE IF NOT EXISTS $tableName (\n  ${cols.join(',\n  ')}\n)',
  ];

  final suffix = _indexSuffix(tableName);
  ddl.add(
    'CREATE UNIQUE INDEX IF NOT EXISTS ix_${suffix}_server_name '
    'ON $tableName(server_name) WHERE server_name IS NOT NULL',
  );
  ddl.add(
    'CREATE INDEX IF NOT EXISTS ix_${suffix}_status ON $tableName(sync_status)',
  );
  ddl.add(
    'CREATE INDEX IF NOT EXISTS ix_${suffix}_modified ON $tableName(modified)',
  );

  final additional = chooseIndexes(
    meta,
    maxIndexes: maxIndexes,
    linkEdgeCount: linkEdgeCount,
  ).where((c) => c != 'server_name' && c != 'sync_status' && c != 'modified');
  for (final col in additional) {
    ddl.add(
      'CREATE INDEX IF NOT EXISTS ix_${suffix}_${_sanitizeColName(col)} '
      'ON $tableName($col)',
    );
  }

  return ddl;
}

String _indexSuffix(String tableName) => tableName.replaceFirst('docs__', '');

String _sanitizeColName(String col) => col.replaceAll('__', '_');
