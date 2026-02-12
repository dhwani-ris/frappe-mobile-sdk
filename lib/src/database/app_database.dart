import 'package:path/path.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'daos/doctype_meta_dao.dart';
import 'daos/document_dao.dart';
import 'daos/link_option_dao.dart';
import 'daos/auth_token_dao.dart';

class AppDatabase {
  static const int _version = 1;
  static Database? _database;
  static AppDatabase? _instance;
  static String? _databaseName;

  final DoctypeMetaDao doctypeMetaDao;
  final DocumentDao documentDao;
  final LinkOptionDao linkOptionDao;
  final AuthTokenDao authTokenDao;

  AppDatabase._(Database database)
    : doctypeMetaDao = DoctypeMetaDao(database),
      documentDao = DocumentDao(database),
      linkOptionDao = LinkOptionDao(database),
      authTokenDao = AuthTokenDao(database);

  /// Get database name from app name (sanitized for filesystem)
  static Future<String> _getDatabaseName() async {
    if (_databaseName != null) return _databaseName!;

    try {
      final packageInfo = await PackageInfo.fromPlatform();
      // Use appName, fallback to packageName if appName is empty
      final appName = packageInfo.appName.isNotEmpty
          ? packageInfo.appName
          : packageInfo.packageName;

      // Sanitize app name for use as filename (remove spaces, special chars)
      final sanitized = appName
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9_-]'), '_')
          .replaceAll(RegExp(r'_+'), '_')
          .replaceAll(RegExp(r'^_|_$'), '');

      _databaseName = '${sanitized}_frappe.db';
      return _databaseName!;
    } catch (e) {
      // Fallback to default name if package_info fails
      _databaseName = 'frappe_mobile_sdk.db';
      return _databaseName!;
    }
  }

  /// Get database instance (singleton)
  static Future<AppDatabase> getInstance() async {
    if (_instance != null) return _instance!;

    if (_database == null) {
      final documentsDirectory = await getDatabasesPath();
      final dbName = await _getDatabaseName();
      final path = join(documentsDirectory, dbName);
      _database = await openDatabase(
        path,
        version: _version,
        onCreate: _onCreate,
        onConfigure: _onConfigure,
      );
    }

    _instance = AppDatabase._(_database!);
    return _instance!;
  }

  /// Create in-memory database for testing
  static Future<AppDatabase> inMemoryDatabase() async {
    final database = await openDatabase(
      inMemoryDatabasePath,
      version: _version,
      onCreate: _onCreate,
      onConfigure: _onConfigure,
    );
    return AppDatabase._(database);
  }

  /// Configure database (enable foreign keys)
  static Future<void> _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  /// Create database tables
  static Future<void> _onCreate(Database db, int version) async {
    // Documents table
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

    // Indexes for documents table
    await db.execute(
      'CREATE INDEX idx_documents_doctype ON documents(doctype)',
    );
    await db.execute('CREATE INDEX idx_documents_status ON documents(status)');
    await db.execute(
      'CREATE INDEX idx_documents_modified ON documents(modified)',
    );

    // DocType metadata table
    await db.execute('''
      CREATE TABLE doctype_meta (
        doctype TEXT PRIMARY KEY,
        modified TEXT,
        serverModifiedAt TEXT,
        isMobileForm INTEGER NOT NULL DEFAULT 0,
        metaJson TEXT NOT NULL
      )
    ''');

    // Index for doctype_meta table
    await db.execute(
      'CREATE INDEX idx_doctype_meta_isMobileForm ON doctype_meta(isMobileForm)',
    );

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

    // Indexes for link_options table
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
  }

  /// Get the underlying database instance (for advanced operations if needed)
  Database get database => _database!;

  /// Close the database
  Future<void> close() async {
    await _database?.close();
    _database = null;
    _instance = null;
  }

  /// Clear all data from all tables. Call on logout to wipe local DB.
  static Future<void> clearAllData() async {
    final db = await getInstance();
    await db.doctypeMetaDao.deleteAll();
    await db.documentDao.deleteAll();
    await db.linkOptionDao.deleteAll();
    await db.authTokenDao.deleteAll();
  }
}
