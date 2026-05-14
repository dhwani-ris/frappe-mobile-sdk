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
  'error_code',
  'sync_attempts',
  'last_attempt_at',
  'sync_op',
  'push_base_payload',
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

/// SDK-internal sync metadata column names — the subset of system columns
/// that must be stripped from any payload going to Frappe. Distinct from
/// [systemParentColumnNames] because Frappe still expects `docstatus` and
/// `modified` on the wire, so this set EXCLUDES those.
///
/// Single source of truth — [PayloadAssembler] (assembles outbound
/// payloads) and [PayloadSerializer] (builds `ThreeWayMerge` base
/// snapshots) both consume this set so the two strip-decisions cannot
/// diverge silently and leak sync metadata into the wire or into a merge
/// base.
const systemSyncMetadataColumnNames = <String>{
  // Identity / link columns — emitted explicitly by the caller.
  'mobile_uuid',
  'server_name',
  // Per-doc sync state.
  'sync_status',
  'sync_error',
  'error_code',
  'sync_attempts',
  'last_attempt_at',
  'sync_op',
  'push_base_payload',
  // Local bookkeeping.
  'local_modified',
  'pulled_at',
};

/// Canonical column-definition fragment for a Link field's `__is_local`
/// companion column. Used by parent and child schema builders and by the
/// runtime ALTER TABLE migration so a column-name or type change is made
/// in exactly one place.
String linkCompanionColumnDDL(String fieldName) =>
    '${fieldName}__is_local INTEGER';
