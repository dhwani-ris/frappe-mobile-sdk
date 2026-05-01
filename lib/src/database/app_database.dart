import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'daos/doctype_meta_dao.dart';
import 'daos/document_dao.dart';
import 'daos/link_option_dao.dart';
import 'daos/auth_token_dao.dart';
import 'daos/doctype_permission_dao.dart';
import 'schema/system_tables.dart';

class AppDatabase {
  static const int _version = 5;

  /// Singleton instance for the production (on-disk) database. The in-memory
  /// factory does NOT touch this — each call returns an independent instance
  /// for hermetic tests.
  static AppDatabase? _instance;
  static String? _databaseName;

  /// Underlying sqflite handle. Held per-instance so both production and
  /// in-memory test databases work identically through [database] /
  /// [rawDatabase] / DAOs.
  final Database _db;

  final DoctypeMetaDao doctypeMetaDao;
  final DocumentDao documentDao;
  final LinkOptionDao linkOptionDao;
  final AuthTokenDao authTokenDao;
  final DoctypePermissionDao doctypePermissionDao;

  AppDatabase._(Database database)
    : _db = database,
      doctypeMetaDao = DoctypeMetaDao(database),
      documentDao = DocumentDao(database),
      linkOptionDao = LinkOptionDao(database),
      authTokenDao = AuthTokenDao(database),
      doctypePermissionDao = DoctypePermissionDao(database);

  /// Get database name from app name (sanitized for filesystem)
  static Future<String> _getDatabaseName({String? appNameOverride}) async {
    if (_databaseName != null) return _databaseName!;

    if (appNameOverride != null && appNameOverride.trim().isNotEmpty) {
      final sanitized = _sanitizeName(appNameOverride);
      _databaseName = sanitized.isEmpty
          ? 'frappe_mobile_sdk.db'
          : '${sanitized}_frappe.db';
      return _databaseName!;
    }

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final appName = packageInfo.appName.isNotEmpty
          ? packageInfo.appName
          : packageInfo.packageName;

      if (appName.isEmpty || appName.trim().isEmpty) {
        _databaseName = 'frappe_mobile_sdk.db';
        return _databaseName!;
      }

      final sanitized = _sanitizeName(appName);

      if (sanitized.isEmpty) {
        _databaseName = 'frappe_mobile_sdk.db';
        return _databaseName!;
      }

      _databaseName = '${sanitized}_frappe.db';
      return _databaseName!;
    } catch (e) {
      _databaseName = 'frappe_mobile_sdk.db';
      return _databaseName!;
    }
  }

  static String _sanitizeName(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  /// Get database instance (singleton).
  static Future<AppDatabase> getInstance({String? appName}) async {
    if (_instance != null) return _instance!;

    final documentsDirectory = await getDatabasesPath();
    final dbName = await _getDatabaseName(appNameOverride: appName);
    final path = join(documentsDirectory, dbName);
    final db = await openDatabase(
      path,
      version: _version,
      onCreate: _onCreate,
      onConfigure: _onConfigure,
      onUpgrade: _onUpgrade,
    );
    _instance = AppDatabase._(db);
    return _instance!;
  }

  /// Create in-memory database for testing.
  /// Each call returns a fresh isolated database (singleInstance: false).
  static Future<AppDatabase> inMemoryDatabase() async {
    final database = await openDatabase(
      inMemoryDatabasePath,
      version: _version,
      onCreate: _onCreate,
      onConfigure: _onConfigure,
      onUpgrade: _onUpgrade,
      singleInstance: false,
    );
    return AppDatabase._(database);
  }

  /// Migrate database schema on upgrade
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE doctype_meta ADD COLUMN groupName TEXT');
      await db.execute('ALTER TABLE doctype_meta ADD COLUMN sortOrder INTEGER');
    }
    if (oldVersion < 3) {
      for (final stmt in systemTablesDDL()) {
        await db.execute(stmt);
      }
      for (final stmt in doctypeMetaExtensionsDDL()) {
        // ALTER TABLE ADD COLUMN throws "duplicate column" on re-entry
        // after a partial migration. Tolerate that one error so
        // _onUpgrade is idempotent. Any other DatabaseException still
        // rethrows.
        try {
          await db.execute(stmt);
        } on DatabaseException catch (e) {
          if (!e.toString().toLowerCase().contains('duplicate column')) {
            rethrow;
          }
        }
      }
    }
    if (oldVersion < 4) {
      for (final stmt in doctypeMetaV4ExtensionsDDL()) {
        // Same duplicate-column guard as v3 — SIG-12 schema bump.
        try {
          await db.execute(stmt);
        } on DatabaseException catch (e) {
          if (!e.toString().toLowerCase().contains('duplicate column')) {
            rethrow;
          }
        }
      }
      await applyV3ToV4Attachments(db);
    }
    if (oldVersion < 5) {
      for (final stmt in sdkMetaV5ExtensionsDDL()) {
        try {
          await db.execute(stmt);
        } on DatabaseException catch (e) {
          if (!e.toString().toLowerCase().contains('duplicate column')) {
            rethrow;
          }
        }
      }
    }
  }

  /// Configure database (enable foreign keys)
  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Create database tables
  static Future<void> _onCreate(Database db, int version) async {
    // Documents table (legacy v1; preserved for migration to read from
    // and for backward compatibility during the rollout window)
    await db.execute('''
      CREATE TABLE documents (
        localId TEXT PRIMARY KEY,
        doctype TEXT NOT NULL,
        serverId TEXT,
        dataJson TEXT NOT NULL,
        status TEXT NOT NULL,
        modified INTEGER NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_documents_doctype ON documents(doctype)',
    );
    await db.execute('CREATE INDEX idx_documents_status ON documents(status)');
    await db.execute(
      'CREATE INDEX idx_documents_modified ON documents(modified)',
    );

    // DocType metadata table — base shape (legacy + groupName/sortOrder)
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL,
        groupName TEXT,
        sortOrder INTEGER
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_doctype_meta_isMobileForm ON doctype_meta(isMobileForm)',
    );

    // Apply v3 doctype_meta extensions on a fresh install. Wrapped in
    // duplicate-column guard for symmetry with _onUpgrade — fresh
    // installs shouldn't hit duplicates, but the symmetry prevents
    // regressions if _onCreate is ever invoked twice (e.g. by
    // clearAllData's recreate path on a partially-rebuilt DB).
    for (final stmt in doctypeMetaExtensionsDDL()) {
      try {
        await db.execute(stmt);
      } on DatabaseException catch (e) {
        if (!e.toString().toLowerCase().contains('duplicate column')) {
          rethrow;
        }
      }
    }

    // v4 doctype_meta extensions on a fresh install. Same duplicate-column
    // guard as the v3 block above.
    for (final stmt in doctypeMetaV4ExtensionsDDL()) {
      try {
        await db.execute(stmt);
      } on DatabaseException catch (e) {
        if (!e.toString().toLowerCase().contains('duplicate column')) {
          rethrow;
        }
      }
    }

    // Link options table
    await db.execute('''
      CREATE TABLE link_options (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doctype TEXT NOT NULL,
        name TEXT NOT NULL,
        label TEXT,
        dataJson TEXT,
        lastUpdated INTEGER NOT NULL
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_link_options_doctype ON link_options(doctype)',
    );
    await db.execute(
      'CREATE INDEX idx_link_options_lastUpdated ON link_options(lastUpdated)',
    );

    // Auth tokens table
    await db.execute('''
      CREATE TABLE auth_tokens (
        id INTEGER PRIMARY KEY,
        accessToken TEXT NOT NULL,
        refreshToken TEXT NOT NULL,
        user TEXT NOT NULL,
        fullName TEXT,
        createdAt INTEGER NOT NULL
      )
    ''');

    await _createDoctypePermissionTable(db);

    // P1 v3: SDK system tables (outbox, pending_attachments, sdk_meta)
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
  }

  static Future<void> _createDoctypePermissionTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS doctype_permission (
        doctype TEXT PRIMARY KEY,
        can_read INTEGER NOT NULL DEFAULT 0,
        can_write INTEGER NOT NULL DEFAULT 0,
        can_create INTEGER NOT NULL DEFAULT 0,
        can_delete INTEGER NOT NULL DEFAULT 0,
        can_submit INTEGER NOT NULL DEFAULT 0,
        can_cancel INTEGER NOT NULL DEFAULT 0,
        can_amend INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  /// Get the underlying database instance (for advanced operations if needed)
  Database get database => _db;

  /// Alias for [database] used by SDK-internal code (P1 offline-first).
  Database get rawDatabase => _db;

  /// Close the database. If this instance is the production singleton, also
  /// clear the static slot so a subsequent [getInstance] reopens cleanly.
  Future<void> close() async {
    await _db.close();
    if (identical(this, _instance)) {
      _instance = null;
    }
  }

  /// Drops every `docs__<doctype>` table and clears `outbox`,
  /// `pending_attachments`, `link_options`. Preserves `doctype_meta`,
  /// `auth_tokens`, `doctype_permission`, `sdk_meta`. Used by the
  /// offline → online transition (Spec §7.5).
  Future<void> wipeOfflineDocumentTables() async {
    await _db.transaction((txn) async {
      final tables = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name LIKE 'docs\\_\\_%' ESCAPE '\\'",
      );
      for (final r in tables) {
        final name = r['name'] as String;
        await txn.execute('DROP TABLE IF EXISTS "$name"');
      }
      await txn.delete('outbox');
      await txn.delete('pending_attachments');
      await txn.delete('link_options');
    });
  }

  /// Clear all local data. Call on logout to wipe the device's local DB.
  /// Drops every application-owned table (mirrors, system tables, legacy
  /// `documents`, etc.) and rebuilds the base schema from scratch.
  /// Per-doctype tables are rebuilt lazily on the next pull via
  /// `OfflineRepository.ensureSchemaForClosure`.
  static Future<void> clearAllData() async {
    final db = await getInstance();
    await _clearAllDataInternal(db._db);
  }

  /// Test seam — same logic as [clearAllData] but operates on this
  /// instance without going through [getInstance]. Production code should
  /// call [clearAllData] (which routes through the singleton).
  @visibleForTesting
  Future<void> clearAllDataForTesting() => _clearAllDataInternal(_db);

  /// Drops every application-owned table (anything not in SQLite's
  /// internal namespace) and rebuilds the base schema by re-running
  /// [_onCreate]. SQLite internals (`sqlite_master`, `sqlite_sequence`,
  /// `sqlite_stat*`) are preserved.
  ///
  /// Tables wiped include — non-exhaustively — `documents`,
  /// `doctype_meta`, `link_options`, `auth_tokens`, `doctype_permission`,
  /// `outbox`, `pending_attachments`, `sdk_meta`, every `docs__*` mirror
  /// table, and any future SDK-owned table. The contract is `NOT LIKE
  /// 'sqlite_%'`: if it's not a SQLite internal, it gets dropped.
  static Future<void> _clearAllDataInternal(Database db) async {
    await db.transaction((txn) async {
      final tables = await txn.rawQuery(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%'",
      );
      for (final r in tables) {
        final tableName = r['name'] as String;
        await txn.execute('DROP TABLE IF EXISTS "$tableName"');
      }
    });

    // Recreate the base schema. _onCreate brings back: documents,
    // doctype_meta (with v3 extensions), link_options, auth_tokens,
    // doctype_permission, outbox, pending_attachments, sdk_meta, plus
    // all associated indexes. Per-doctype docs__* tables are NOT
    // recreated here — they are rebuilt lazily on the next pull via
    // OfflineRepository.ensureSchemaForClosure.
    await _onCreate(db, _version);

    // _onCreate inserts sdk_meta with schema_version=0. Bump to 2 so
    // V1ToV2Migration.run() correctly skips on next call — there is
    // nothing to migrate from the now-empty `documents` table.
    await db.update('sdk_meta', <String, Object?>{
      'schema_version': 2,
    }, where: 'id = 1');
  }
}

/// Applied as part of `_onUpgrade(oldVersion < 4)`. Exposed at top level
/// so the migration test can run it directly against an in-memory DB
/// shaped like a pre-v4 schema, without dragging in the SIG-12 column work.
///
/// Adds `top_parent_uuid` + `top_parent_doctype` to `pending_attachments`
/// (nullable; DAO enforces non-null at insert) and creates the
/// `ix_attach_top_parent` index. Backfills pre-existing rows from
/// `parent_uuid` / `parent_doctype` — pre-fix only parent-level attaches
/// existed because attach_field.dart never wired `dao.enqueue`.
Future<void> applyV3ToV4Attachments(Database db) async {
  const stmts = <String>[
    'ALTER TABLE pending_attachments ADD COLUMN top_parent_uuid TEXT',
    'ALTER TABLE pending_attachments ADD COLUMN top_parent_doctype TEXT',
    'CREATE INDEX IF NOT EXISTS ix_attach_top_parent '
        'ON pending_attachments(top_parent_uuid, state)',
  ];
  for (final stmt in stmts) {
    try {
      await db.execute(stmt);
    } on DatabaseException catch (e) {
      if (!e.toString().toLowerCase().contains('duplicate column')) {
        rethrow;
      }
    }
  }
  await db.execute(
    'UPDATE pending_attachments '
    'SET top_parent_uuid = parent_uuid, '
    '    top_parent_doctype = parent_doctype '
    'WHERE top_parent_uuid IS NULL',
  );
}
