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
    tmpDir = Directory.systemTemp.createTempSync('migration_reentrant_');
    dbPath = p.join(tmpDir.path, 'test.db');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  test(
    'rerunning migration on a partially-upgraded DB completes without throwing',
    () async {
      // Synthesize the worst-case partial-upgrade state: the schema deltas
      // landed (doctype_meta has v3+v4 columns, outbox/pending_attachments/
      // sdk_meta exist) but PRAGMA user_version is still 2 (e.g. OS killed
      // the process between txn commit and pragma write). The next open
      // must re-run _migrateV2ToV3 without throwing.
      final db = await openDatabase(
        dbPath,
        version: 2,
        singleInstance: false,
        onCreate: (db, _) async {
          // Build doctype_meta WITH all v3+v4 columns already present.
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
          // Build the system tables already in their final shape.
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
          // Note: deliberately leave out the sdk_meta singleton row to test
          // that the migration's INSERT OR REPLACE recovers from a missing
          // row.
        },
      );
      await db.close();

      // Reopen at v3 — _onUpgrade fires on a partially-shaped DB.
      final reopened = await openDatabase(
        dbPath,
        version: 3,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );

      // The migration must have completed cleanly.
      final pragma = await reopened.rawQuery('PRAGMA user_version');
      expect(pragma.first.values.first, 3);

      // sdk_meta row recovered via INSERT OR REPLACE.
      final meta = await reopened.query('sdk_meta', where: 'id = 1');
      expect(meta, hasLength(1));
      expect(meta.first['schema_version'], 3);

      await reopened.close();
    },
  );
}
