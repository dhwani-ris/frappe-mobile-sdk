/// Frappe's server-owned audit fields, materialized as nullable `TEXT` on
/// every PARENT `docs__<doctype>` table.
///
/// They exist offline so a filter referencing them produces real SQL. Before
/// they were materialized, `FilterParser.toSql` REJECTED such a clause with
/// `Unknown column` — the filter was unusable offline rather than permissive,
/// and callers worked around it by omitting the clause. An intermediate
/// revision dropped the clause silently instead, which is strictly worse:
/// dropping an AND clause makes an offline result a SUPERSET of the server
/// query, degrading `owner = <current user>` to a no-op that surfaces rows
/// which are not the user's. Both are gone. See the matching note on
/// `FilterParser._parentAuditColumns`, which this deliberately mirrors — the
/// earlier version of this docstring recorded only the silent-drop half and
/// contradicted it.
///
/// The server is AUTHORITATIVE. Frappe assigns `owner` / `creation` on insert
/// and `modified_by` on every save, and a client must never SEND them — they
/// are in [systemSyncMetadataColumnNames], so both the outbound payload and
/// the `ThreeWayMerge` base strip them. That is a security property: it is
/// what stops a client forging `owner`.
///
/// A row created ON THE DEVICE is nevertheless stamped with a LOCAL PREDICTION
/// (`LocalWriter._resolveParentAudit`): `owner` / `modified_by` = the session
/// user, `creation` = now. This is not fabrication — Frappe assigns `owner` to
/// the authenticated user performing the insert, so the prediction is what the
/// server will confirm, and Frappe's own web client does the same
/// (`frappe.model.get_new_doc` sets `owner = frappe.session.user`). Without it
/// the creator's own offline draft is missing from their own
/// `owner = <me>` list — the record looks lost.
///
/// Server truth always overwrites the prediction, from both directions:
/// `PullApply._copyServerAuditFields` on pull, and
/// `ResponseWriteback.applyInTxn` on a successful push. Neither routes through
/// [LocalWriter], so the prediction can never block them. An UPDATE preserves
/// the existing `owner` / `creation` (authorship belongs to the creator); only
/// `modified_by` moves.
///
/// PARENT ONLY — `child_schema.dart` does not emit these, so
/// [systemChildColumnNames] deliberately excludes them and `FilterParser`
/// whitelists them only when `!meta.isTable`.
const serverAuditColumnNames = <String>{'owner', 'creation', 'modified_by'};

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
  ...serverAuditColumnNames,
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
  // Server-owned audit fields. Frappe assigns these itself, so a client
  // that sent them would at best be rejected by validation and at worst
  // forge document attribution (`owner` drives permission checks). Stripped
  // from BOTH the outbound payload and the `ThreeWayMerge` base so the two
  // agree — see [serverAuditColumnNames].
  ...serverAuditColumnNames,
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
    '"${fieldName}__is_local" INTEGER';
