// Fix 2 / AC#6 — v4 upgrade self-heal for the poisoned permission-skip table.
//
// Field devices poisoned by the PRE-hardening skip logic (a transient 403
// storm that permanently skipped Member / geo masters) carry a
// `permission_skip_doctypes` table full of stale rows. The v4 migration
// (`AppDatabase._onUpgrade`, gated `oldVersion < 4`) DROPs that table ONCE so
// those devices recover WITHOUT re-login. `SdkMetaDao._ensureSkipTable` then
// lazily recreates the CURRENT 2-column (denied_at_ms) shape on next use.
// Fresh installs never had the table (`_onCreate` doesn't create it), so they
// are unaffected.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<bool> _tableExists(Database db, String name) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
    [name],
  );
  return rows.isNotEmpty;
}

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

  test(
    'v4 upgrade DROPs the poisoned permission_skip_doctypes table without re-login',
    () async {
      // 1. Seed a pre-v4 (version 3) device carrying the LEGACY 1-column skip
      //    table with a poisoned row — exactly the stuck state field devices
      //    were in before hardening.
      final v3 = await openDatabase(
        dbPath,
        version: 3,
        singleInstance: false,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE permission_skip_doctypes '
            '(doctype TEXT PRIMARY KEY NOT NULL)',
          );
          await db.insert('permission_skip_doctypes', {'doctype': 'Member'});
          await db.insert('permission_skip_doctypes', {'doctype': 'Village'});
        },
      );
      final seeded = await v3.query('permission_skip_doctypes');
      expect(seeded, hasLength(2), reason: 'sanity: poisoned rows are present');
      await v3.close();

      // 2. Reopen at v4 — `_onUpgrade` fires with oldVersion=3, newVersion=4.
      final v4 = await openDatabase(
        dbPath,
        version: 4,
        onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
        singleInstance: false,
      );

      // 3. Migration version bumped.
      final pragma = await v4.rawQuery('PRAGMA user_version');
      expect(pragma.first.values.first, 4);

      // 4. The poisoned table is GONE (dropped, not just emptied).
      expect(
        await _tableExists(v4, 'permission_skip_doctypes'),
        isFalse,
        reason: 'the v4 migration drops the poisoned skip table outright',
      );

      // 5. Self-heal complete: the DAO lazily recreates the CURRENT 2-column
      //    shape and reads empty — no re-login required.
      final dao = SdkMetaDao(v4);
      expect(
        await dao.readActiveSkippedDoctypes(
          nowMs: DateTime.now().toUtc().millisecondsSinceEpoch,
        ),
        isEmpty,
      );
      final cols = await v4.rawQuery('PRAGMA table_info(permission_skip_doctypes)');
      expect(
        cols.map((r) => r['name']).toSet(),
        containsAll(<String>{'doctype', 'denied_at_ms'}),
        reason: 'the recreated table carries the expiry column',
      );

      await v4.close();
    },
  );

  test(
    'a fresh v4 install never has permission_skip_doctypes until first use',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      addTearDown(() => appDb.close());

      // _onCreate does NOT create the skip table — fresh installs were never
      // poisoned, so there is nothing to drop.
      expect(
        await _tableExists(appDb.rawDatabase, 'permission_skip_doctypes'),
        isFalse,
      );
    },
  );
}
