import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'daos/doctype_meta_dao.dart';
import '../utils/sdk_log.dart';
import 'daos/link_option_dao.dart';
import 'daos/auth_token_dao.dart';
import 'daos/doctype_permission_dao.dart';
import 'daos/security_event_dao.dart';
import 'daos/security_state_dao.dart';
import 'schema/system_columns.dart';
import 'schema/system_tables.dart';
import 'table_name.dart';

/// Injectable factory resolver — allows tests to substitute their own
/// factory (e.g. one that always throws) without mocking internals.
typedef DatabaseFactoryResolver =
    Future<DatabaseFactory> Function(
      void Function(Object, StackTrace)? onFailure,
    );

class AppDatabase {
  static const int _version = 7;

  /// Singleton instance for the production (on-disk) database. The in-memory
  /// factory does NOT touch this — each call returns an independent instance
  /// for hermetic tests.
  static AppDatabase? _instance;
  static Future<AppDatabase>? _instanceFuture;
  static String? _databaseName;

  /// Underlying sqflite handle. Held per-instance so both production and
  /// in-memory test databases work identically through [database] /
  /// [rawDatabase] / DAOs.
  final Database _db;

  final DoctypeMetaDao doctypeMetaDao;
  final LinkOptionDao linkOptionDao;
  final AuthTokenDao authTokenDao;
  final DoctypePermissionDao doctypePermissionDao;
  final SecurityStateDao securityStateDao;
  final SecurityEventDao securityEventDao;

  AppDatabase._(Database database)
    : _db = database,
      doctypeMetaDao = DoctypeMetaDao(database),
      linkOptionDao = LinkOptionDao(database),
      authTokenDao = AuthTokenDao(database),
      doctypePermissionDao = DoctypePermissionDao(database),
      securityStateDao = SecurityStateDao(database),
      securityEventDao = SecurityEventDao(database);

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
      sdkLog(
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

  static Future<DatabaseFactory> _resolveDatabaseFactory(
    void Function(Object, StackTrace)? onFfiInitFailure,
  ) async {
    try {
      sqfliteFfiInit();
      // Liveness probe only — no schema callbacks; keeps smoke test fast.
      final smokeDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 1),
      );
      await smokeDb.close();
      return databaseFactoryFfi;
    } catch (e, st) {
      sdkLog(
        'AppDatabase: FFI init failed → falling back to sqflite — $e\n$st',
      );
      onFfiInitFailure?.call(e, st);
      return databaseFactory;
    }
  }

  static Future<AppDatabase> getInstance({
    String? appName,
    void Function(Object, StackTrace)? onFfiInitFailure,
    DatabaseFactoryResolver? factoryResolver,
  }) {
    if (_instance != null) return Future.value(_instance!);
    return _instanceFuture ??=
        _createInstance(
          appName: appName,
          onFfiInitFailure: onFfiInitFailure,
          factoryResolver: factoryResolver,
        ).catchError((Object e, StackTrace st) {
          _instanceFuture = null; // allow retry on next call
          return Future<AppDatabase>.error(e, st);
        });
  }

  static Future<AppDatabase> _createInstance({
    String? appName,
    void Function(Object, StackTrace)? onFfiInitFailure,
    DatabaseFactoryResolver? factoryResolver,
  }) async {
    // Resolve the path BEFORE sqfliteFfiInit() runs. sqfliteFfiInit() overrides
    // the global databaseFactory to databaseFactoryFfi; after that,
    // getDatabasesPath() calls the FFI isolate, which cannot make platform
    // channel calls and returns the wrong path (SQLITE_CANTOPEN, error 14).
    // Calling it here uses the MethodChannel factory — always correct on Android/iOS.
    final documentsDirectory = await getDatabasesPath();
    final resolve = factoryResolver ?? _resolveDatabaseFactory;
    final factory = await resolve(onFfiInitFailure);
    final dbName = await _getDatabaseName(appNameOverride: appName);
    final path = join(documentsDirectory, dbName);
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _version,
        onCreate: _onCreate,
        onConfigure: _onConfigure,
        onUpgrade: _onUpgrade,
      ),
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
    if (oldVersion < 4) {
      await _migrateV3ToV4(db);
    }
    if (oldVersion < 5) {
      await _migrateV4ToV5(db);
    }
    if (oldVersion < 6) {
      await _migrateV5ToV6(db);
    }
    if (oldVersion < 7) {
      await _migrateV6ToV7(db);
    }
  }

  /// v6 → v7: add the `media_cache` content store.
  ///
  /// Nothing is backfilled. The cache is non-authoritative by construction —
  /// an empty table just means every lookup is a miss and re-fetches on
  /// demand — so there is no migration of existing files to perform.
  ///
  /// Existing `pending_attachments` rows keep working untouched: they store an
  /// absolute `local_path`, so a file staged by an older build under the old
  /// flat layout still uploads and still moves into the cache from wherever it
  /// actually is.
  static Future<void> _migrateV6ToV7(Database db) async {
    await db.transaction((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS media_cache (
          file_url TEXT PRIMARY KEY,
          local_path TEXT NOT NULL,
          size_bytes INTEGER,
          mime_type TEXT,
          is_private INTEGER NOT NULL DEFAULT 1,
          source TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          last_accessed_at INTEGER
        )
      ''');
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS ix_media_cache_accessed ON media_cache(last_accessed_at)',
      );
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS ix_media_cache_source ON media_cache(source)',
      );
      await txn.rawUpdate(
        'UPDATE sdk_meta SET schema_version = 7 WHERE id = 1',
      );
    });
  }

  /// v5 → v6: materialize Frappe's server-owned audit columns (`owner`,
  /// `creation`, `modified_by`) on every existing `docs__<doctype>` PARENT
  /// mirror table.
  ///
  /// Why this must be a versioned migration rather than relying on the
  /// per-doctype reconcile: `FilterParser` now emits real SQL for these
  /// columns instead of silently dropping the clause, so a table created by
  /// an older SDK build fails any such query with `no such column: owner`.
  /// The reconcile paths that could add them
  /// (`OfflineRepository.ensureSchemaForClosure` / `reconcileParentTableForMeta`)
  /// only run during a pull, and the closure pull is gated on connectivity —
  /// an app that upgrades and then starts OFFLINE would query the old schema
  /// first. `onUpgrade` runs on `openDatabase`, before any query can.
  ///
  /// Child mirrors share the `docs__` prefix but `child_schema.dart` does not
  /// emit these columns, so they are identified by the absence of the
  /// parent-only `sync_status` column and left untouched — otherwise an
  /// upgraded install's child tables would drift from a fresh install's.
  ///
  /// Every column is nullable `TEXT` with no default: the server is their only
  /// writer, and SQLite rejects `ADD COLUMN ... NOT NULL` without a default.
  /// Wrapped in [_safeAddColumn] so an interrupted upgrade can re-run.
  ///
  /// Adding the columns is necessary but NOT sufficient, which is why this also
  /// clears every pull cursor. The new columns start NULL on existing rows, and
  /// once a doctype is `complete` all later pulls are incremental
  /// (`modified >= cursor.modified`) — so an upgraded install would only ever
  /// receive audit values for rows whose `modified` advances server-side, and
  /// every pre-existing row would keep NULL indefinitely. Since equality
  /// comparisons go through `IFNULL(<col>, '')`, `owner = <me>` would then match
  /// none of them. The failure mode is a SILENTLY PARTIAL result — recently
  /// touched rows appear, the rest do not — which is materially harder to
  /// notice than the `no such column` throw this migration replaced.
  ///
  /// Nulling `last_ok_cursor` makes the next sync re-drain each doctype and
  /// backfill the values. It is one statement, atomic with the ALTERs, and
  /// costs one full re-pull once per upgraded install. `forceFullRepull` on
  /// [FrappeSDK] is the host-callable equivalent for later re-drains —
  /// `forcePullAll` is NOT, because it excludes entry-point doctypes, which are
  /// exactly the mobile-form doctypes where `owner = <me>` is the point.
  static Future<void> _migrateV5ToV6(Database db) async {
    await db.transaction((txn) async {
      final tables = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      for (final row in tables) {
        final name = row['name'] as String;
        if (!name.startsWith('docs__')) continue;
        final info = await txn.rawQuery('PRAGMA table_info("$name")');
        final cols = info.map((r) => r['name'] as String?).toSet();
        // Parent-only marker — see `systemChildColumnNames`, which has no
        // `sync_*` columns because children inherit the parent's state.
        //
        // Requiring `parent_uuid` to be ABSENT is not redundant: `sync_status`
        // is not in `systemChildColumnNames`, and `child_schema.dart` emits
        // every mappable DocField as a column, so a child doctype declaring a
        // field literally named `sync_status` would otherwise be treated as a
        // parent and have the audit columns ALTERed onto it — the exact
        // child/fresh-install drift this check exists to prevent.
        if (!cols.contains('sync_status')) continue;
        if (cols.contains('parent_uuid')) continue;
        for (final col in serverAuditColumnNames) {
          if (cols.contains(col)) continue;
          await _safeAddColumn(
            txn,
            'ALTER TABLE "$name" ADD COLUMN "$col" TEXT',
          );
        }
        // Match `buildParentSchemaDDL` so an upgraded install gets the same
        // `owner` index a fresh one does — otherwise `owner = <me>` stays a full
        // scan on exactly the installs that already hold the most rows.
        // `IF NOT EXISTS` keeps the re-run safe.
        final suffix = name.startsWith('docs__')
            ? name.substring('docs__'.length)
            : name;
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS "ix_${suffix}_owner" ON "$name"(owner)',
        );
      }

      // `last_ok_cursor` is added by `doctypeMetaExtensionsDDL()` on the v2→v3
      // leg, which `_onUpgrade` always runs before this one, so it is present on
      // any DB reaching v6. Checked anyway: an unexpected throw here would roll
      // back the ALTERs above and leave the schema unmigrated.
      final metaCols = await txn.rawQuery('PRAGMA table_info(doctype_meta)');
      final hasCursor = metaCols.any((r) => r['name'] == 'last_ok_cursor');
      if (hasCursor) {
        await txn.rawUpdate('UPDATE doctype_meta SET last_ok_cursor = NULL');
      }

      await txn.rawUpdate(
        'UPDATE sdk_meta SET schema_version = 6 WHERE id = 1',
      );
    });
  }

  /// v3 → v4: add the `kv` translation-cache table that TranslationDao writes to.
  /// Devices that were on v3 before this PR will not have this table, so we must
  /// create it here. `CREATE TABLE IF NOT EXISTS` makes the step idempotent for
  /// devices that reach v4 via a v2→v4 path (where _migrateV2ToV3 already ran
  /// systemTablesDDL which includes the kv DDL).
  static Future<void> _migrateV3ToV4(Database db) async {
    await db.transaction((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS kv (
          lang TEXT NOT NULL,
          src  TEXT NOT NULL,
          tgt  TEXT NOT NULL,
          PRIMARY KEY (lang, src)
        )
      ''');
      await txn.rawUpdate(
        'UPDATE sdk_meta SET schema_version = 4 WHERE id = 1',
      );
    });
  }

  /// v4 → v5: add the two security tables (`security_state`, `security_events`)
  /// introduced in the tamper-detection feature. `CREATE TABLE IF NOT EXISTS`
  /// and `INSERT OR IGNORE` make every statement idempotent so the migration
  /// is safe to re-run after an interrupted upgrade.
  static Future<void> _migrateV4ToV5(Database db) async {
    await db.transaction((txn) async {
      for (final stmt in securityTablesDDL()) {
        await txn.execute(stmt);
      }

      // Backfill the mobile_uuid index on docs__* tables that were created
      // before `mobile_uuid` was seeded into IndexPolicy (devices upgrading
      // from v3/v4). `mobile_uuid` is the TEXT PRIMARY KEY, so SQLite already
      // auto-indexes it and equality lookups never scan — but creating the
      // named `ix_<suffix>_mobile_uuid` index keeps upgraded DBs byte-for-byte
      // consistent with freshly-created ones (same name as parent_schema.dart
      // emits) and removes any doubt for the UUID-fallback pull path. Idempotent
      // via IF NOT EXISTS.
      final docTables = await txn.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      );
      for (final row in docTables) {
        final name = row['name'] as String;
        if (!name.startsWith('docs__')) continue;
        final suffix = stripDocsPrefix(name);
        await txn.execute(
          'CREATE INDEX IF NOT EXISTS ix_${suffix}_mobile_uuid '
          'ON "$name"(mobile_uuid)',
        );
      }

      await txn.rawUpdate(
        'UPDATE sdk_meta SET schema_version = 5 WHERE id = 1',
      );
    });
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

  static Future<void> _onConfigure(Database db) async {
    final walResult = await db.rawQuery('PRAGMA journal_mode=WAL');
    final actualMode = walResult.isNotEmpty && walResult.first.values.isNotEmpty
        ? walResult.first.values.first?.toString().toLowerCase()
        : null;
    if (actualMode != 'wal' && actualMode != 'memory') {
      sdkLog(
        'AppDatabase._onConfigure: WARNING — WAL mode not active '
        '(got "$actualMode"). Write throughput will be reduced.',
      );
    }

    await db.execute('PRAGMA foreign_keys = ON');
    await db.execute('PRAGMA synchronous=NORMAL');
    await db.execute('PRAGMA cache_size=-32768');
    await db.execute('PRAGMA mmap_size=268435456');
    await db.execute('PRAGMA temp_store=MEMORY');
  }

  /// Fresh-install path. Builds every table in its final v3 shape.
  /// Post-condition is identical to running [_migrateV2ToV3] on a v2 DB —
  /// see `app_database_fresh_vs_upgraded_test.dart`.
  ///
  /// Thin wrapper over [_onCreateBody] so sqflite's `onCreate` callback
  /// can keep its `Database` signature. [_clearAllDataInternal] calls
  /// [_onCreateBody] directly with a [Transaction] so the wipe + rebuild
  /// happen atomically.
  static Future<void> _onCreate(Database db, int version) =>
      _onCreateBody(db, version);

  /// Builds the base schema. Accepts any [DatabaseExecutor] so it can run
  /// either on a fresh `Database` (sqflite's `onCreate` path) or inside
  /// a `Transaction` (the `clearAllData` rebuild path that needs to be
  /// atomic with the preceding DROP loop).
  static Future<void> _onCreateBody(DatabaseExecutor exec, int version) async {
    await exec.execute('''
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
    await exec.execute(
      'CREATE INDEX idx_doctype_meta_isMobileForm ON doctype_meta(isMobileForm)',
    );

    // doctype_meta v3 + v4 column extensions. Fresh installs apply them
    // directly — no duplicate-column guard needed because the table is
    // brand new.
    for (final stmt in [
      ...doctypeMetaExtensionsDDL(),
      ...doctypeMetaV4ExtensionsDDL(),
    ]) {
      await exec.execute(stmt);
    }

    await exec.execute('''
      CREATE TABLE link_options (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doctype TEXT NOT NULL,
        name TEXT NOT NULL,
        label TEXT,
        dataJson TEXT,
        lastUpdated INTEGER NOT NULL
      )
    ''');
    await exec.execute(
      'CREATE INDEX idx_link_options_doctype ON link_options(doctype)',
    );
    await exec.execute(
      'CREATE INDEX idx_link_options_lastUpdated ON link_options(lastUpdated)',
    );

    await exec.execute('''
      CREATE TABLE auth_tokens (
        id INTEGER PRIMARY KEY,
        accessToken TEXT NOT NULL,
        refreshToken TEXT NOT NULL,
        user TEXT NOT NULL,
        fullName TEXT,
        createdAt INTEGER NOT NULL
      )
    ''');

    await _createDoctypePermissionTable(exec);

    // System tables (outbox, pending_attachments, sdk_meta) in final shape.
    for (final stmt in systemTablesDDL()) {
      await exec.execute(stmt);
    }

    // Security tables (security_state, security_events) introduced in v5.
    for (final stmt in securityTablesDDL()) {
      await exec.execute(stmt);
    }

    // Singleton upsert — same shape as the migration to keep _onCreate
    // and _onUpgrade post-conditions identical.
    //
    // Uses the [version] argument rather than a literal: this was hardcoded to
    // 6 and silently drifted from `_version` on the v6->v7 bump, leaving a
    // fresh install reporting schema_version=6 while PRAGMA user_version said
    // 7. Threading the parameter makes the two impossible to disagree.
    await exec.insert('sdk_meta', <String, Object?>{
      'id': 1,
      'schema_version': version,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _createDoctypePermissionTable(
    DatabaseExecutor exec,
  ) async {
    await exec.execute('''
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
      _instanceFuture = null;
      _databaseName = null;
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
  /// internal namespace) and rebuilds the base schema by running
  /// [_onCreateBody]. SQLite internals (`sqlite_master`, `sqlite_sequence`,
  /// `sqlite_stat*`) are preserved.
  ///
  /// Tables wiped include — non-exhaustively —
  /// `doctype_meta`, `link_options`, `auth_tokens`, `doctype_permission`,
  /// `outbox`, `pending_attachments`, `sdk_meta`, every `docs__*` mirror
  /// table, and any future SDK-owned table. The contract is `NOT LIKE
  /// 'sqlite_%'`: if it's not a SQLite internal, it gets dropped.
  ///
  /// DROP loop + rebuild run in ONE transaction. Otherwise a process
  /// kill between the two would leave application tables dropped but
  /// `PRAGMA user_version` untouched — the next `openDatabase(version:3)`
  /// would skip both `onCreate` and `onUpgrade` and hard-brick the DB
  /// until the user clears app data manually (PR#36 round-2 H4).
  static Future<void> _clearAllDataInternal(Database db) async {
    await db.transaction((txn) async {
      await _dropTablesWhere(txn, "name NOT LIKE 'sqlite_%'");
      // Recreate the base schema inside the same txn. _onCreateBody
      // brings back doctype_meta (with v3+v4 extensions), link_options,
      // auth_tokens, doctype_permission, outbox, pending_attachments,
      // sdk_meta, plus all associated indexes. Per-doctype docs__*
      // tables are NOT recreated here — they are rebuilt lazily on the
      // next pull via OfflineRepository.ensureSchemaForClosure. Without
      // this rebuild a process kill mid-clear would brick the DB (the
      // next openDatabase(version:3) skips both onCreate and onUpgrade).
      await _onCreateBody(txn, _version);
    });
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

  static Future<void> runOnConfigure(Database db) =>
      AppDatabase._onConfigure(db);

  static int get version => AppDatabase._version;

  /// Resets the production singleton so tests that call [AppDatabase.getInstance]
  /// start from a clean state. Never call from production code.
  static void resetSingleton() {
    AppDatabase._instance = null;
    AppDatabase._instanceFuture = null;
    AppDatabase._databaseName = null;
  }
}
