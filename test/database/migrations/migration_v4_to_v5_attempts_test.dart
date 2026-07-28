// Fix B / T-B8 — DB v4→v5: the slim `outbox` gains a per-row `attempts`
// counter (auto-retry budget). Fresh installs get it from `systemTablesDDL()`;
// upgraded field devices get it from the additive, idempotent ALTER in
// `_onUpgrade` (gated `oldVersion < 5`, wrapped in `_safeAddColumn`).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Set<String>> outboxColumns(Database db) async {
  final rows = await db.rawQuery('PRAGMA table_info(outbox)');
  return rows.map((r) => r['name'] as String).toSet();
}

// The pre-v5 outbox shape (no `attempts`) as it existed on-device when the DB
// first reached v3 — the real starting point the v5 ALTER must migrate.
const _preV5OutboxDDL =
    'CREATE TABLE outbox ('
    'id INTEGER PRIMARY KEY AUTOINCREMENT, '
    'doctype TEXT NOT NULL, '
    'mobile_uuid TEXT NOT NULL, '
    'operation TEXT NOT NULL, '
    'state TEXT NOT NULL, '
    'created_at INTEGER NOT NULL, '
    'error_code TEXT, '
    'error_message TEXT)';

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

  test('fresh v5 install has outbox.attempts defaulting to 0', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    addTearDown(() => appDb.close());

    expect(await outboxColumns(appDb.rawDatabase), contains('attempts'));

    final dao = OutboxDao(appDb.rawDatabase);
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.insert,
    );
    expect((await dao.findById(id))!.attempts, 0);
  });

  test('v4→v5 upgrade adds attempts (default 0 on existing rows), idempotently',
      () async {
    // 1. Seed a pre-v5 (version 4) device with the attempts-less outbox + a row.
    final v4 = await openDatabase(
      dbPath,
      version: 4,
      singleInstance: false,
      onCreate: (db, _) async {
        await db.execute(_preV5OutboxDDL);
        await db.insert('outbox', {
          'doctype': 'X',
          'mobile_uuid': 'u',
          'operation': 'INSERT',
          'state': 'failed',
          'created_at': 1,
          'error_code': 'NETWORK',
        });
      },
    );
    expect(
      await outboxColumns(v4),
      isNot(contains('attempts')),
      reason: 'sanity: the seeded device is in the pre-v5 shape',
    );
    await v4.close();

    // 2. Reopen at v5 — `_onUpgrade` fires with oldVersion=4, newVersion=5.
    final v5 = await openDatabase(
      dbPath,
      version: AppDatabaseTestSeam.version,
      onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
      singleInstance: false,
    );

    expect((await v5.rawQuery('PRAGMA user_version')).first.values.first, 5);
    expect(await outboxColumns(v5), contains('attempts'));

    final rows = await v5.query('outbox');
    expect(rows, hasLength(1), reason: 'the existing row survives the upgrade');
    expect(
      rows.first['attempts'],
      0,
      reason: 'existing rows backfill to the DEFAULT 0',
    );

    // 3. Re-running the ALTER must be a no-op (interrupted-upgrade safety).
    await AppDatabaseTestSeam.runOnUpgrade(v5, 4, 5);
    expect(await outboxColumns(v5), contains('attempts'));

    await v5.close();
  });

  test('fresh v5 and upgraded v5 agree on the outbox column set', () async {
    final seed = await openDatabase(
      dbPath,
      version: 4,
      singleInstance: false,
      onCreate: (db, _) async => db.execute(_preV5OutboxDDL),
    );
    await seed.close();

    final upgraded = await openDatabase(
      dbPath,
      version: AppDatabaseTestSeam.version,
      onUpgrade: AppDatabaseTestSeam.runOnUpgrade,
      singleInstance: false,
    );
    final upgradedCols = await outboxColumns(upgraded);
    await upgraded.close();

    final fresh = await AppDatabase.inMemoryDatabase();
    addTearDown(() => fresh.close());
    final freshCols = await outboxColumns(fresh.rawDatabase);

    expect(upgradedCols, equals(freshCols));
  });
}
