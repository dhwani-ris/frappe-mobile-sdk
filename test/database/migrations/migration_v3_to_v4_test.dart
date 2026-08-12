import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Verifies that a device already at schema v3 (i.e. running 2.0.0 before the
/// kv table was introduced) gets the kv table created when upgrading to v4.
/// This is the critical regression path: fresh-installs and v2→v4 upgrades
/// both create kv inside systemTablesDDL, but an existing v3 device skips
/// both onCreate AND _migrateV2ToV3, so only _migrateV3ToV4 runs.
void main() {
  late Directory tmpDir;
  late String dbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('migration_v3_v4_');
    dbPath = p.join(tmpDir.path, 'test.db');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  // Simulate the _onCreate body as it shipped in v3 (before kv was added).
  // This is the schema that an in-wild v3 device has — NO kv table.
  Future<void> v3OnCreate(Database db, int _) async {
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
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_outbox_state ON outbox(state, created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS ix_outbox_uuid ON outbox(mobile_uuid)',
    );
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
    await db.insert('sdk_meta', {'id': 1, 'schema_version': 3});
  }

  test(
    'v3 → v4: kv table created, schema_version bumped, existing data preserved',
    () async {
      // 1. Build a v3 DB (no kv table) and seed data that must survive.
      final v3 = await openDatabase(
        dbPath,
        version: 3,
        onCreate: v3OnCreate,
        singleInstance: false,
      );

      await v3.insert('auth_tokens', {
        'id': 1,
        'accessToken': 'tok',
        'refreshToken': 'ref',
        'user': 'alice@example.com',
        'fullName': 'Alice',
        'createdAt': 1700000000000,
      });
      await v3.insert('sdk_meta', {
        'id': 1,
        'schema_version': 3,
        'session_user_json': '{"name":"alice"}',
        'bootstrap_done': 1,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      // Confirm kv does NOT exist before migration.
      final kvBefore = await v3.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='kv'",
      );
      expect(kvBefore, isEmpty, reason: 'kv must not exist in a v3 DB');

      final pragmaBefore = await v3.rawQuery('PRAGMA user_version');
      expect(pragmaBefore.first.values.first, 3);
      await v3.close();

      // 2. Reopen at v5 — _onUpgrade fires with oldVersion=3, running
      //    _migrateV3ToV4 then _migrateV4ToV5.
      final v4 = await openDatabase(
        dbPath,
        version: 5,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );

      // 3a. user_version pragma bumped to 5.
      final pragmaAfter = await v4.rawQuery('PRAGMA user_version');
      expect(pragmaAfter.first.values.first, 5);

      // 3b. kv table now exists.
      final kvAfter = await v4.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='kv'",
      );
      expect(kvAfter, hasLength(1), reason: '_migrateV3ToV4 must create kv');

      // 3c. kv table has correct schema.
      final kvCols = await v4.rawQuery('PRAGMA table_info(kv)');
      final colNames = kvCols.map((r) => r['name'] as String).toSet();
      expect(colNames, containsAll(<String>{'lang', 'src', 'tgt'}));

      // 3d. sdk_meta.schema_version updated to 6 (full v3→v6 chain ran).
      final meta = await v4.query('sdk_meta', where: 'id = 1');
      expect(meta, hasLength(1));
      expect(meta.first['schema_version'], 6);

      // 3e. Existing data preserved — auth_tokens still intact.
      final at = await v4.query('auth_tokens');
      expect(at, hasLength(1));
      expect(at.first['user'], 'alice@example.com');

      // 3f. Session data in sdk_meta preserved — bootstrap_done still 1.
      expect(meta.first['bootstrap_done'], 1);
      expect(meta.first['session_user_json'], '{"name":"alice"}');

      // 3g. kv is usable — insert and query round-trip works.
      await v4.insert('kv', {'lang': 'hi', 'src': 'Hello', 'tgt': 'नमस्ते'});
      final kvRows = await v4.query('kv', where: 'lang = ?', whereArgs: ['hi']);
      expect(kvRows, hasLength(1));
      expect(kvRows.first['tgt'], 'नमस्ते');

      await v4.close();
    },
  );

  test('v3 → v4: _migrateV3ToV4 is idempotent (kv already exists)', () async {
    // Simulates the v2→v4 path where _migrateV2ToV3 already created kv
    // via systemTablesDDL, then _migrateV3ToV4 runs again. Must not throw.
    final v3 = await openDatabase(
      dbPath,
      version: 3,
      onCreate: v3OnCreate,
      singleInstance: false,
    );
    // Manually create kv as _migrateV2ToV3 would have.
    await v3.execute('''
        CREATE TABLE IF NOT EXISTS kv (
          lang TEXT NOT NULL,
          src  TEXT NOT NULL,
          tgt  TEXT NOT NULL,
          PRIMARY KEY (lang, src)
        )
      ''');
    await v3.close();

    // Reopening at v5 should succeed without "table already exists" error.
    final v4 = await openDatabase(
      dbPath,
      version: 5,
      onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
      singleInstance: false,
    );
    final kvAfter = await v4.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='kv'",
    );
    expect(kvAfter, hasLength(1));
    await v4.close();
  });
}
