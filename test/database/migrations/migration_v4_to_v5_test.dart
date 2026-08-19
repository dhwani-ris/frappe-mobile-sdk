import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Builds the exact schema a v4 device has (before security tables).
Future<void> _v4OnCreate(Database db, int _) async {
  await db.execute('''
    CREATE TABLE doctype_meta (
      doctype TEXT PRIMARY KEY,
      modified TEXT,
      serverModifiedAt TEXT,
      isMobileForm INTEGER NOT NULL DEFAULT 0,
      metaJson TEXT NOT NULL,
      groupName TEXT,
      sortOrder INTEGER,
      table_name TEXT,
      meta_watermark TEXT,
      dep_graph_json TEXT,
      last_ok_cursor TEXT,
      last_pull_started_at INTEGER,
      last_pull_ok_at INTEGER,
      is_entry_point INTEGER NOT NULL DEFAULT 0,
      is_child_table INTEGER NOT NULL DEFAULT 0,
      record_count INTEGER,
      is_parent_with_children INTEGER NOT NULL DEFAULT 0
    )
  ''');
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
  await db.execute('''
    CREATE TABLE doctype_permission (
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
  await db.execute('''
    CREATE TABLE outbox (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      doctype TEXT NOT NULL,
      mobile_uuid TEXT NOT NULL,
      operation TEXT NOT NULL,
      state TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      error_code TEXT,
      error_message TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE pending_attachments (
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
  ''');
  await db.execute('''
    CREATE TABLE sdk_meta (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      schema_version INTEGER NOT NULL DEFAULT 0,
      session_user_json TEXT,
      bootstrap_done INTEGER NOT NULL DEFAULT 0,
      offline_enabled INTEGER NOT NULL DEFAULT 0,
      offline_enabled_set_at INTEGER
    )
  ''');
  await db.insert('sdk_meta', {'id': 1, 'schema_version': 4});
  await db.execute('''
    CREATE TABLE kv (
      lang TEXT NOT NULL,
      src  TEXT NOT NULL,
      tgt  TEXT NOT NULL,
      PRIMARY KEY (lang, src)
    )
  ''');
}

void main() {
  late Directory tmpDir;
  late String dbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('migration_v4_v5_');
    dbPath = p.join(tmpDir.path, 'test.db');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  test(
    'v4 device gets security_state and security_events on upgrade to v5',
    () async {
      final v4db = await openDatabase(
        dbPath,
        version: 4,
        onCreate: _v4OnCreate,
        singleInstance: false,
      );
      await v4db.close();

      AppDatabaseTestSeam.resetSingleton();
      final v5db = await openDatabase(
        dbPath,
        version: 5,
        onConfigure: AppDatabaseTestSeam.runOnConfigure,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );

      final tables = (await v5db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name'] as String).toSet();

      expect(tables, contains('security_state'));
      expect(tables, contains('security_events'));

      // security_state must have singleton row seeded by migration
      final stateRows = await v5db.rawQuery('SELECT id FROM security_state');
      expect(stateRows, hasLength(1));
      expect(stateRows.first['id'], 1);

      // sdk_meta schema_version must be bumped to 6 — `_onUpgrade` branches on
      // oldVersion only, so a v4 device runs the full v4→v7 chain.
      final meta = await v5db.rawQuery(
        'SELECT schema_version FROM sdk_meta WHERE id = 1',
      );
      expect(meta.first['schema_version'], 7);

      await v5db.close();
    },
  );

  test(
    'fresh install via AppDatabase.inMemoryDatabase creates both security tables',
    () async {
      AppDatabaseTestSeam.resetSingleton();
      final db = await AppDatabase.inMemoryDatabase();

      final tables = (await db.rawDatabase.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      )).map((r) => r['name'] as String).toSet();

      expect(tables, contains('security_state'));
      expect(tables, contains('security_events'));

      await db.close();
    },
  );

  test(
    'v4→v5 backfills the named mobile_uuid index on existing docs__ tables (H4)',
    () async {
      final v4db = await openDatabase(
        dbPath,
        version: 4,
        onCreate: (db, v) async {
          await _v4OnCreate(db, v);
          // A docs__ table as a v3/v4 device would have it: mobile_uuid is the
          // PRIMARY KEY (auto-indexed) but the NAMED ix_<suffix>_mobile_uuid
          // index that newer IndexPolicy emits is absent.
          await db.execute(
            'CREATE TABLE docs__demo ('
            '  mobile_uuid TEXT PRIMARY KEY,'
            '  server_name TEXT,'
            '  sync_status TEXT'
            ')',
          );
        },
        singleInstance: false,
      );
      // Precondition: the named index does not exist yet on the v4 table.
      final before = (await v4db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND tbl_name='docs__demo'",
      )).map((r) => r['name'] as String).toSet();
      expect(before, isNot(contains('ix_demo_mobile_uuid')));
      await v4db.close();

      AppDatabaseTestSeam.resetSingleton();
      final v5db = await openDatabase(
        dbPath,
        version: 5,
        onConfigure: AppDatabaseTestSeam.runOnConfigure,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );

      final after = (await v5db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' "
        "AND tbl_name='docs__demo'",
      )).map((r) => r['name'] as String).toSet();
      expect(
        after,
        contains('ix_demo_mobile_uuid'),
        reason: 'migration must backfill the named mobile_uuid index',
      );

      await v5db.close();
    },
  );

  test('migration is idempotent — running v4→v5 twice does not throw', () async {
    final v4db = await openDatabase(
      dbPath,
      version: 4,
      onCreate: _v4OnCreate,
      singleInstance: false,
    );
    await v4db.close();

    AppDatabaseTestSeam.resetSingleton();
    // First upgrade
    final db1 = await openDatabase(
      dbPath,
      version: 5,
      onConfigure: AppDatabaseTestSeam.runOnConfigure,
      onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
      singleInstance: false,
    );
    await db1.close();

    AppDatabaseTestSeam.resetSingleton();
    // Second open at v5 — onUpgrade not called again by SQLite
    final db2 = await openDatabase(
      dbPath,
      version: 5,
      onConfigure: AppDatabaseTestSeam.runOnConfigure,
      singleInstance: false,
    );

    final count =
        (await db2.rawQuery(
              "SELECT count(*) as c FROM sqlite_master WHERE type='table' AND name='security_state'",
            )).first['c']
            as int;
    expect(count, 1);

    await db2.close();
  });
}
