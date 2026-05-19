// DDL for SDK system tables (outbox, pending_attachments, sdk_meta)
// plus an extension block for the pre-existing doctype_meta table.
// Returned as raw DDL string lists; AppDatabase executes them in its
// onCreate / onUpgrade handlers inside a transaction.

// `IF NOT EXISTS` / `OR IGNORE` make `systemTablesDDL()` idempotent so
// it can be safely re-run by `_onUpgrade` after a partial migration
// failure. `doctypeMetaExtensionsDDL()` is NOT idempotent on its own —
// SQLite's `ALTER TABLE ADD COLUMN` does not support `IF NOT EXISTS` in
// older versions, so the call site (`app_database.dart`) wraps each
// ALTER in a try/catch on "duplicate column name" to make it
// re-entry-safe.
List<String> systemTablesDDL() => <String>[
  '''
      CREATE TABLE IF NOT EXISTS outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doctype TEXT NOT NULL,
        mobile_uuid TEXT NOT NULL,
        operation TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        error_code TEXT,
        error_message TEXT
      )
      ''',
  'CREATE INDEX IF NOT EXISTS ix_outbox_state ON outbox(state, created_at)',
  'CREATE INDEX IF NOT EXISTS ix_outbox_uuid ON outbox(mobile_uuid)',
  '''
      CREATE TABLE IF NOT EXISTS pending_attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_uuid TEXT NOT NULL,
        parent_doctype TEXT NOT NULL,
        parent_fieldname TEXT NOT NULL,
        top_parent_uuid TEXT,
        top_parent_doctype TEXT,
        local_path TEXT NOT NULL,
        file_name TEXT,
        mime_type TEXT,
        is_private INTEGER NOT NULL DEFAULT 1,
        size_bytes INTEGER,
        state TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER,
        error_message TEXT,
        server_file_name TEXT,
        server_file_url TEXT,
        created_at INTEGER NOT NULL
      )
      ''',
  'CREATE INDEX IF NOT EXISTS ix_attach_state ON pending_attachments(state)',
  'CREATE INDEX IF NOT EXISTS ix_attach_parent ON pending_attachments(parent_uuid, parent_fieldname)',
  'CREATE INDEX IF NOT EXISTS ix_attach_top_parent ON pending_attachments(top_parent_uuid, state)',
  '''
      CREATE TABLE IF NOT EXISTS sdk_meta (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        schema_version INTEGER NOT NULL DEFAULT 0,
        session_user_json TEXT,
        bootstrap_done INTEGER NOT NULL DEFAULT 0,
        offline_enabled INTEGER NOT NULL DEFAULT 0,
        offline_enabled_set_at INTEGER
      )
      ''',
  'INSERT OR IGNORE INTO sdk_meta (id, schema_version) VALUES (1, 0)',
];

/// ALTER statements to add the new columns to a pre-existing
/// doctype_meta table (created by an earlier SDK version).
List<String> doctypeMetaExtensionsDDL() => <String>[
  'ALTER TABLE doctype_meta ADD COLUMN table_name TEXT',
  'ALTER TABLE doctype_meta ADD COLUMN meta_watermark TEXT',
  'ALTER TABLE doctype_meta ADD COLUMN dep_graph_json TEXT',
  'ALTER TABLE doctype_meta ADD COLUMN last_ok_cursor TEXT',
  'ALTER TABLE doctype_meta ADD COLUMN last_pull_started_at INTEGER',
  'ALTER TABLE doctype_meta ADD COLUMN last_pull_ok_at INTEGER',
  'ALTER TABLE doctype_meta ADD COLUMN is_entry_point INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE doctype_meta ADD COLUMN is_child_table INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE doctype_meta ADD COLUMN record_count INTEGER',
];

/// v4 extension: SIG-12 persistent child-table registry. Adds a single
/// boolean column on `doctype_meta` so `OfflineRepository.doctypesWithChildren`
/// can survive process restarts without rebuilding the in-memory cache first.
///
/// Like `doctypeMetaExtensionsDDL`, this is NOT idempotent on its own —
/// SQLite's ALTER TABLE ADD COLUMN does not support `IF NOT EXISTS` on
/// the versions we support, so the call site (`app_database.dart`) wraps
/// each ALTER in a try/catch on "duplicate column name".
List<String> doctypeMetaV4ExtensionsDDL() => <String>[
  'ALTER TABLE doctype_meta '
      'ADD COLUMN is_parent_with_children INTEGER NOT NULL DEFAULT 0',
];
