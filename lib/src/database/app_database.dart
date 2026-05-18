import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'daos/doctype_meta_dao.dart';
import 'daos/link_option_dao.dart';
import 'daos/auth_token_dao.dart';
import 'daos/doctype_permission_dao.dart';
import 'schema/system_tables.dart';

class AppDatabase {
  static const int _version = 3;

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
  final LinkOptionDao linkOptionDao;
  final AuthTokenDao authTokenDao;
  final DoctypePermissionDao doctypePermissionDao;

  AppDatabase._(Database database)
    : _db = database,
      doctypeMetaDao = DoctypeMetaDao(database),
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
    } catch (e, st) {
      debugPrint(
        'AppDatabase._resolveDatabaseName: PackageInfo lookup failed, falling back to default — $e\n$st',
      );
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

  /// Migrate a 1.1.0 / DB v2 device to 2.0.0 / DB v3 in a single
  /// transaction. The four intermediate steps (v3, v4, v5, v6) that
  /// existed during offline-first development are collapsed: no device
  /// in the wild is at any of those versions.
  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 3) {
      await _migrateV2ToV3(db);
    }
  }

  static Future<void> _migrateV2ToV3(Database db) async {
    await db.transaction((txn) async {
      // 1. doctype_meta column adds (only non-idempotent statements).
      for (final stmt in [
        ...doctypeMetaExtensionsDDL(),
        ...doctypeMetaV4ExtensionsDDL(),
      ]) {
        await _safeAddColumn(txn, stmt);
      }

      // 2. System tables in their final shape (CREATE TABLE IF NOT EXISTS
      //    is already idempotent; no guard needed).
      for (final stmt in systemTablesDDL()) {
        await txn.execute(stmt);
      }

      // 3. Drop legacy `documents` table and its indexes (DROP IF EXISTS
      //    is already idempotent; no guard needed). Confirmed safe: the
      //    1.1.0 SDK pushes before persisting, so no dirty rows survive.
      await txn.execute('DROP TABLE IF EXISTS documents');
      await txn.execute('DROP INDEX IF EXISTS idx_documents_doctype');
      await txn.execute('DROP INDEX IF EXISTS idx_documents_status');
      await txn.execute('DROP INDEX IF EXISTS idx_documents_modified');

      // 4. Singleton upsert. Recovers from a missing or corrupted row.
      await txn.insert('sdk_meta', <String, Object?>{
        'id': 1,
        'schema_version': 3,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Wraps a non-idempotent `ALTER TABLE ADD COLUMN` so the migration
  /// remains safe to re-run after an interrupted upgrade. SQLite raises
  /// a `DatabaseException` containing "duplicate column name" when the
  /// column already exists; everything else is rethrown.
  static Future<void> _safeAddColumn(Transaction txn, String sql) async {
    try {
      await txn.execute(sql);
    } on DatabaseException catch (e) {
      if (!e.toString().toLowerCase().contains('duplicate column name')) {
        rethrow;
      }
    }
  }

  /// Configure database (enable foreign keys)
  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Fresh-install path. Builds every table in its final v3 shape.
  /// Post-condition is identical to running [_migrateV2ToV3] on a v2 DB —
  /// see `app_database_fresh_vs_upgraded_test.dart`.
  static Future<void> _onCreate(Database db, int version) async {
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

    // doctype_meta v3 + v4 column extensions. Fresh installs apply them
    // directly — no duplicate-column guard needed because the table is
    // brand new.
    for (final stmt in [
      ...doctypeMetaExtensionsDDL(),
      ...doctypeMetaV4ExtensionsDDL(),
    ]) {
      await db.execute(stmt);
    }

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

    // System tables (outbox, pending_attachments, sdk_meta) in final shape.
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }

    // Singleton upsert — same shape as the migration to keep _onCreate
    // and _onUpgrade post-conditions identical.
    await db.insert('sdk_meta', <String, Object?>{
      'id': 1,
      'schema_version': 3,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  /// Selects table names from `sqlite_master` matching [whereClause] (with
  /// optional bind [args]) and runs `DROP TABLE IF EXISTS "<name>"` for
  /// each. Shared by [wipeOfflineDocumentTables] (drops `docs__*` mirrors
  /// only) and [_clearAllDataInternal] (drops everything except SQLite
  /// internals) so the predicate is the only thing that varies.
  static Future<void> _dropTablesWhere(
    DatabaseExecutor txn,
    String whereClause, [
    List<Object?>? args,
  ]) async {
    final tables = await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND $whereClause",
      args,
    );
    for (final r in tables) {
      final name = r['name'] as String;
      await txn.execute('DROP TABLE IF EXISTS "$name"');
    }
  }

  /// Drops every `docs__<doctype>` table and clears `outbox`,
  /// `pending_attachments`, `link_options`. Preserves `doctype_meta`,
  /// `auth_tokens`, `doctype_permission`, `sdk_meta` — except for the
  /// `bootstrap_done` flag, which is reset to 0 because the per-doctype
  /// mirrors that bootstrap built are gone. Used by the offline → online
  /// transition (Spec §7.5).
  Future<void> wipeOfflineDocumentTables() async {
    await _db.transaction((txn) async {
      await _dropTablesWhere(txn, r"name LIKE 'docs\_\_%' ESCAPE '\'");
      await txn.delete('outbox');
      await txn.delete('pending_attachments');
      await txn.delete('link_options');
      // bootstrap_done marks "the SDK finished its first-time docs__
      // bootstrap" — after a wipe that no longer holds, so reset.
      await txn.rawUpdate(
        'UPDATE sdk_meta SET bootstrap_done = 0 WHERE id = 1',
      );
    });
  }

  /// Clear all local data. Call on logout to wipe the device's local DB.
  /// Drops every application-owned table (mirrors, system tables, etc.)
  /// and rebuilds the base schema from scratch. Per-doctype tables are
  /// rebuilt lazily on the next pull via
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
  /// Tables wiped include — non-exhaustively —
  /// `doctype_meta`, `link_options`, `auth_tokens`, `doctype_permission`,
  /// `outbox`, `pending_attachments`, `sdk_meta`, every `docs__*` mirror
  /// table, and any future SDK-owned table. The contract is `NOT LIKE
  /// 'sqlite_%'`: if it's not a SQLite internal, it gets dropped.
  static Future<void> _clearAllDataInternal(Database db) async {
    await db.transaction((txn) async {
      await _dropTablesWhere(txn, "name NOT LIKE 'sqlite_%'");
    });

    // Recreate the base schema. _onCreate brings back: doctype_meta
    // (with v3+v4 extensions), link_options, auth_tokens,
    // doctype_permission, outbox, pending_attachments, sdk_meta, plus
    // all associated indexes. Per-doctype docs__* tables are NOT
    // recreated here — they are rebuilt lazily on the next pull via
    // OfflineRepository.ensureSchemaForClosure. _onCreate already
    // INSERT-OR-REPLACEs sdk_meta with schema_version=3.
    await _onCreate(db, _version);
  }
}

/// Test-only seam exposing private `_onUpgrade` and `_version` so
/// migration tests can drive them via `openDatabase`. Production code
/// never touches this.
@visibleForTesting
class AppDatabaseTestSeam {
  static Future<void> runOnUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) => AppDatabase._onUpgrade(db, oldVersion, newVersion);

  static int get version => AppDatabase._version;
}
