import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Pins the migration → gate-default contract: after a 1.1.0 / DB v2
/// device upgrades to v3, the SDK reads `OfflineMode.fallback` and
/// stays online until the server explicitly flips the flag (which sets
/// `offline_enabled_set_at` to a non-NULL value).
///
/// `sdk_meta_dao_test.dart` separately covers the DAO contract on a
/// freshly-built `systemTablesDDL()` schema. This test exists to pin the
/// link between *the migration path* and that contract.
void main() {
  late Directory tmpDir;
  late String dbPath;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('post_migration_gate_');
    dbPath = p.join(tmpDir.path, 'test.db');
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Future<void> developV2OnCreate(Database db, int _) async {
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
      CREATE TABLE documents (
        localId TEXT PRIMARY KEY,
        doctype TEXT NOT NULL,
        serverId TEXT,
        dataJson TEXT NOT NULL,
        status TEXT NOT NULL,
        modified INTEGER NOT NULL
      )
    ''');
  }

  test(
    'post-migration default state: SdkMetaDao reports OfflineMode.fallback',
    () async {
      final v2 = await openDatabase(
        dbPath,
        version: 2,
        onCreate: developV2OnCreate,
        singleInstance: false,
      );
      await v2.close();

      final v3 = await openDatabase(
        dbPath,
        version: 3,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );

      // Migration writes sdk_meta with offline_enabled=0 and
      // offline_enabled_set_at=NULL. The DAO contract maps that to
      // OfflineMode.fallback (enabled=false, isPersisted=false). The
      // runtime gate (FrappeSDK + OfflineRepository) reads enabled=false
      // and routes every read/write to REST. A separate flip via
      // writeOfflineMode (set_at non-null) would be needed to switch to
      // offline mode.
      final dao = SdkMetaDao(v3);
      final mode = await dao.readOfflineMode();
      expect(mode, equals(OfflineMode.fallback));
      expect(mode.enabled, isFalse);
      expect(mode.isPersisted, isFalse);

      // Defensive: confirm the underlying row is in the expected shape.
      final rows = await v3.query('sdk_meta', where: 'id = 1');
      expect(rows.first['offline_enabled'], 0);
      expect(rows.first['offline_enabled_set_at'], isNull);
      expect(rows.first['bootstrap_done'], 0);

      await v3.close();
    },
  );
}
