import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() => AppDatabaseTestSeam.resetSingleton());

  test('readState returns all-null before any write', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final state = await db.securityStateDao.readState();
    expect(state['last_wall_time_ms'], isNull);
    expect(state['last_monotonic_ms'], isNull);
    expect(state['last_run_at_ms'], isNull);
    await db.close();
  });

  test('writeState + readState round-trips all three fields', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.securityStateDao.writeState(
      wallTimeMs: 1000000,
      monotonicMs: 500000,
      runAtMs: 1000000,
    );
    final state = await db.securityStateDao.readState();
    expect(state['last_wall_time_ms'], 1000000);
    expect(state['last_monotonic_ms'], 500000);
    expect(state['last_run_at_ms'], 1000000);
    await db.close();
  });

  test('second writeState updates values — exactly one row persists', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.securityStateDao.writeState(
      wallTimeMs: 1000000,
      monotonicMs: 500000,
      runAtMs: 1000000,
    );
    await db.securityStateDao.writeState(
      wallTimeMs: 2000000,
      monotonicMs: 1500000,
      runAtMs: 2000000,
    );
    final state = await db.securityStateDao.readState();
    expect(state['last_wall_time_ms'], 2000000);
    expect(state['last_monotonic_ms'], 1500000);

    final rows = await db.rawDatabase.rawQuery(
      'SELECT COUNT(*) AS c FROM security_state',
    );
    expect(rows.first['c'], 1);
    await db.close();
  });

  test('writeState with null monotonicMs stores null', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.securityStateDao.writeState(
      wallTimeMs: 1000000,
      monotonicMs: null,
      runAtMs: 1000000,
    );
    final state = await db.securityStateDao.readState();
    expect(state['last_wall_time_ms'], 1000000);
    expect(state['last_monotonic_ms'], isNull);
    await db.close();
  });

  test(
    'writeState does not create a second row (UPDATE-then-INSERT-OR-IGNORE guard)',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.securityStateDao.writeState(
        wallTimeMs: 100,
        monotonicMs: 50,
        runAtMs: 100,
      );
      await db.securityStateDao.writeState(
        wallTimeMs: 200,
        monotonicMs: null,
        runAtMs: 200,
      );
      final rows = await db.rawDatabase.rawQuery(
        'SELECT COUNT(*) AS c FROM security_state',
      );
      expect(
        rows.first['c'],
        1,
        reason:
            'INSERT OR REPLACE would create a second row on conflict; '
            'UPDATE-then-INSERT-OR-IGNORE must not',
      );
      await db.close();
    },
  );
}
