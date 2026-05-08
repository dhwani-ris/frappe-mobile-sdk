import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmpDir;
  late String dbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('migration_v2_v3_');
    dbPath = p.join(tmpDir.path, 'test.db');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  // The exact _onCreate body shipped in develop (1.1.0 / DB v2). We
  // reconstruct it here so the test seeds a true v2 database without
  // depending on any code that has been deleted from this branch.
  Future<void> developV2OnCreate(Database db, int _) async {
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
  }

  test(
    'v2 → v3: schema deltas, data preservation, sdk_meta.schema_version',
    () async {
      // 1. Build a v2 DB and seed every table that should survive.
      final v2 = await openDatabase(
        dbPath,
        version: 2,
        onCreate: developV2OnCreate,
        singleInstance: false,
      );

      await v2.insert('doctype_meta', <String, Object?>{
        'doctype': 'Mobile Form',
        'modified': '2026-05-09 10:00:00',
        'serverModifiedAt': '2026-05-09 10:00:00',
        'isMobileForm': 1,
        'metaJson': '{}',
        'groupName': 'Forms',
        'sortOrder': 1,
      });
      await v2.insert('link_options', <String, Object?>{
        'doctype': 'State',
        'name': 'Karnataka',
        'label': 'Karnataka',
        'dataJson': '{}',
        'lastUpdated': 1700000000000,
      });
      await v2.insert('auth_tokens', <String, Object?>{
        'id': 1,
        'accessToken': 'access',
        'refreshToken': 'refresh',
        'user': 'user@example.com',
        'fullName': 'Test User',
        'createdAt': 1700000000000,
      });
      await v2.insert('documents', <String, Object?>{
        'localId': 'doc-1',
        'doctype': 'Mobile Form',
        'serverId': 'MF-0001',
        'dataJson': '{}',
        'status': 'clean',
        'modified': 1700000000000,
      });

      // Verify pragma is at 2 before reopen.
      final pragmaBefore = await v2.rawQuery('PRAGMA user_version');
      expect(pragmaBefore.first.values.first, 2);
      await v2.close();

      // 2. Reopen at v3 — _onUpgrade fires.
      final v3 = await openDatabase(
        dbPath,
        version: 3,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );

      // 3a. user_version pragma is bumped.
      final pragmaAfter = await v3.rawQuery('PRAGMA user_version');
      expect(pragmaAfter.first.values.first, 3);

      // 3b. doctype_meta row preserved; new columns default to NULL/0.
      final dt = await v3.query(
        'doctype_meta',
        where: 'doctype = ?',
        whereArgs: ['Mobile Form'],
      );
      expect(dt, hasLength(1));
      expect(dt.first['groupName'], 'Forms');
      expect(dt.first['is_entry_point'], 0);
      expect(dt.first['is_child_table'], 0);
      expect(dt.first['is_parent_with_children'], 0);
      expect(dt.first['table_name'], isNull);

      // 3c. auth_tokens preserved.
      final at = await v3.query('auth_tokens');
      expect(at, hasLength(1));
      expect(at.first['user'], 'user@example.com');

      // 3d. link_options preserved.
      final lo = await v3.query('link_options');
      expect(lo, hasLength(1));

      // 3e. documents table dropped.
      final docTbl = await v3.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='documents'",
      );
      expect(docTbl, isEmpty);

      // 3f. New system tables exist.
      final sysTbls = await v3.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name IN ('outbox','pending_attachments','sdk_meta')",
      );
      expect(
        sysTbls.map((r) => r['name']).toSet(),
        equals({'outbox', 'pending_attachments', 'sdk_meta'}),
      );

      // 3g. sdk_meta row exists with schema_version=3, offline_enabled=0,
      //     bootstrap_done=0.
      final meta = await v3.query('sdk_meta', where: 'id = 1');
      expect(meta, hasLength(1));
      expect(meta.first['schema_version'], 3);
      expect(meta.first['offline_enabled'], 0);
      expect(meta.first['bootstrap_done'], 0);

      await v3.close();
    },
  );
}
