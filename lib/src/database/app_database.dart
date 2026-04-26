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
        await db.execute(stmt);
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

    // Apply v3 doctype_meta extensions on a fresh install.
    for (final stmt in doctypeMetaExtensionsDDL()) {
      await db.execute(stmt);
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

  /// Clear all data from all tables. Call on logout to wipe local DB.
  static Future<void> clearAllData() async {
    final db = await getInstance();
    await db.doctypeMetaDao.deleteAll();
    await db.documentDao.deleteAll();
    await db.linkOptionDao.deleteAll();
    await db.authTokenDao.deleteAll();
    await db.doctypePermissionDao.deleteAll();
  }
}
