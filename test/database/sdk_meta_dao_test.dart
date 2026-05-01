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
}
