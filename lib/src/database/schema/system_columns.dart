/// System column names emitted by the offline-document parent table block.
/// A meta field that uses any of these names is dropped from the meta loop
/// because the system column already covers it (and SQLite rejects duplicate
/// column names in `CREATE TABLE`).
///
/// Single source of truth — `parent_schema.dart` (DDL), `local_writer.dart`
/// (form-save writer), and `sync/pull_apply.dart` (pull writer) all import
/// from here so the column set cannot drift between them.
const systemParentColumnNames = <String>{
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

/// System column names emitted by the offline-document child table block.
/// Children share the parent's `sync_status` so no `sync_*` columns appear
/// here. Same drift-protection rationale as [systemParentColumnNames].
const systemChildColumnNames = <String>{
  'mobile_uuid',
  'server_name',
  'parent_uuid',
  'parent_doctype',
  'parentfield',
  'idx',
  'modified',
};
