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
    tmpDir = Directory.systemTemp.createTempSync('migration_equivalence_');
    dbPath = p.join(tmpDir.path, 'test.db');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<Map<String, List<Map<String, Object?>>>> tableSchemas(
    Database db,
  ) async {
    final names = (await db.rawQuery(
      "SELECT name FROM sqlite_master "
      "WHERE type='table' AND name NOT LIKE 'sqlite_%' "
      "ORDER BY name",
    )).map((r) => r['name'] as String).toList();

    final out = <String, List<Map<String, Object?>>>{};
    for (final n in names) {
      // PRAGMA table_info returns: cid, name, type, notnull, dflt_value, pk
      final info = await db.rawQuery('PRAGMA table_info("$n")');
      out[n] = info
          .map(
            (r) => <String, Object?>{
              'name': r['name'],
              'type': r['type'],
              'notnull': r['notnull'],
              'dflt_value': r['dflt_value'],
              'pk': r['pk'],
            },
          )
          .toList();
    }
    return out;
  }

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
    'migrated DB has the same per-table schema as a fresh install',
    () async {
      // Path 1: fresh install via _onCreate.
      final fresh = await AppDatabase.inMemoryDatabase();
      final freshSchema = await tableSchemas(fresh.rawDatabase);

      // Path 2: build v2, upgrade to v3.
      final v2 = await openDatabase(
        dbPath,
        version: 2,
        onCreate: developV2OnCreate,
        singleInstance: false,
      );
      await v2.close();
      final upgraded = await openDatabase(
        dbPath,
        version: 3,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );
      final upgradedSchema = await tableSchemas(upgraded);

      // Set of tables must match.
      expect(upgradedSchema.keys.toSet(), equals(freshSchema.keys.toSet()));

      // Per-table column shape must match.
      for (final name in freshSchema.keys) {
        expect(
          upgradedSchema[name],
          equals(freshSchema[name]),
          reason: 'Table $name shape diverges between fresh and upgraded.',
        );
      }

      await upgraded.close();
      await fresh.close();
    },
  );
}
