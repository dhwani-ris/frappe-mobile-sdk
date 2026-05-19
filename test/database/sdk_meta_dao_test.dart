import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';

Future<Database> _freshDb() async {
  return await openDatabase(
    inMemoryDatabasePath,
    version: 1,
    onCreate: (db, _) async {
      for (final stmt in systemTablesDDL()) {
        await db.execute(stmt);
      }
    },
    singleInstance: false,
  );
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('readOfflineMode returns fallback when set_at is NULL', () async {
    final db = await _freshDb();
    final dao = SdkMetaDao(db);
    final mode = await dao.readOfflineMode();
    expect(mode, OfflineMode.fallback);
    await db.close();
  });

  test(
    'writeOfflineMode then readOfflineMode round-trips enabled=true',
    () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.writeOfflineMode(enabled: true, setAtMs: 12345);
      final mode = await dao.readOfflineMode();
      expect(mode.enabled, isTrue);
      expect(mode.isPersisted, isTrue);
      await db.close();
    },
  );

  test(
    'writeOfflineMode then readOfflineMode round-trips enabled=false',
    () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.writeOfflineMode(enabled: false, setAtMs: 67890);
      final mode = await dao.readOfflineMode();
      expect(mode.enabled, isFalse);
      expect(mode.isPersisted, isTrue);
      await db.close();
    },
  );

  test('readOfflineMode returns fallback when row is missing', () async {
    final db = await _freshDb();
    await db.delete('sdk_meta');
    final dao = SdkMetaDao(db);
    final mode = await dao.readOfflineMode();
    expect(mode, OfflineMode.fallback);
    await db.close();
  });

  test(
    'writeOfflineMode preserves schema_version, bootstrap_done, session_user_json',
    () async {
      // Regression for PR#36 review item #3. INSERT OR REPLACE wiped the
      // sibling columns back to defaults; the fix is an UPDATE.
      final db = await _freshDb();
      await db.rawUpdate(
        'UPDATE sdk_meta SET schema_version = ?, bootstrap_done = ?, '
        'session_user_json = ? WHERE id = 1',
        [3, 1, '{"user":"alice@example.com"}'],
      );
      final dao = SdkMetaDao(db);
      await dao.writeOfflineMode(enabled: true, setAtMs: 999);

      final rows = await db.rawQuery(
        'SELECT schema_version, bootstrap_done, session_user_json, '
        'offline_enabled, offline_enabled_set_at FROM sdk_meta WHERE id = 1',
      );
      expect(rows, hasLength(1));
      expect(rows.first['schema_version'], 3);
      expect(rows.first['bootstrap_done'], 1);
      expect(rows.first['session_user_json'], '{"user":"alice@example.com"}');
      expect(rows.first['offline_enabled'], 1);
      expect(rows.first['offline_enabled_set_at'], 999);
      await db.close();
    },
  );
}
