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

  group('permission skip-set (403 closure prune, TTL-scoped)', () {
    // Fixed clock so TTL-boundary arithmetic is deterministic.
    const nowMs = 1_800_000_000_000; // ~2027, arbitrary fixed epoch-ms
    final ttl = SdkMetaDao.permissionSkipTtlMs;

    test('readActiveSkippedDoctypes is empty on a fresh install', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      final skipped = await dao.readActiveSkippedDoctypes(nowMs: nowMs);
      expect(skipped, isEmpty);
      await db.close();
    });

    test('addSkippedDoctype then readActiveSkippedDoctypes returns it', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.addSkippedDoctype('User', deniedAtMs: nowMs);
      final skipped = await dao.readActiveSkippedDoctypes(nowMs: nowMs);
      expect(skipped, {'User'});
      await db.close();
    });

    test('addSkippedDoctype stamps denied_at_ms', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.addSkippedDoctype('User', deniedAtMs: nowMs);
      final rows = await db.query('permission_skip_doctypes');
      expect(rows, hasLength(1));
      expect(rows.first['doctype'], 'User');
      expect(rows.first['denied_at_ms'], nowMs);
      await db.close();
    });

    test('addSkippedDoctype accumulates distinct doctypes', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.addSkippedDoctype('User', deniedAtMs: nowMs);
      await dao.addSkippedDoctype('Role', deniedAtMs: nowMs);
      final skipped = await dao.readActiveSkippedDoctypes(nowMs: nowMs);
      expect(skipped, {'User', 'Role'});
      await db.close();
    });

    test(
      'addSkippedDoctype is idempotent per doctype — no duplicate row, stamp refreshed',
      () async {
        final db = await _freshDb();
        final dao = SdkMetaDao(db);
        await dao.addSkippedDoctype('User', deniedAtMs: nowMs - 1000);
        // Re-add of the SAME doctype must not create a second row and must
        // REFRESH the timestamp (INSERT OR REPLACE extends the window).
        await dao.addSkippedDoctype('User', deniedAtMs: nowMs);
        final rows = await db.query('permission_skip_doctypes');
        expect(rows, hasLength(1));
        expect(rows.first['denied_at_ms'], nowMs);
        expect(await dao.readActiveSkippedDoctypes(nowMs: nowMs), {'User'});
        await db.close();
      },
    );

    test('addSkippedDoctype ignores an empty doctype name', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.addSkippedDoctype('', deniedAtMs: nowMs);
      final skipped = await dao.readActiveSkippedDoctypes(nowMs: nowMs);
      expect(skipped, isEmpty);
      await db.close();
    });

    test('removeSkippedDoctype drops a single doctype (200-revisit self-heal)',
        () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.addSkippedDoctype('User', deniedAtMs: nowMs);
      await dao.addSkippedDoctype('Role', deniedAtMs: nowMs);

      await dao.removeSkippedDoctype('User');

      expect(await dao.readActiveSkippedDoctypes(nowMs: nowMs), {'Role'});
      await db.close();
    });

    test('clearSkippedDoctypes empties a populated skip-set', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      await dao.addSkippedDoctype('User', deniedAtMs: nowMs);
      await dao.addSkippedDoctype('Role', deniedAtMs: nowMs);
      expect(await dao.readActiveSkippedDoctypes(nowMs: nowMs), isNotEmpty);

      await dao.clearSkippedDoctypes();

      expect(await dao.readActiveSkippedDoctypes(nowMs: nowMs), isEmpty);
      await db.close();
    });

    test('clearSkippedDoctypes on an already-empty set is a no-op', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      // Never populated — table not even created yet. Must not throw.
      await dao.clearSkippedDoctypes();
      expect(await dao.readActiveSkippedDoctypes(nowMs: nowMs), isEmpty);
      await db.close();
    });

    // ── 2c. Expiry (24h TTL) ──────────────────────────────────────────
    test(
      'an expired skip (denied_at older than TTL) is EXCLUDED so it retries; '
      'a fresh one is included',
      () async {
        final db = await _freshDb();
        final dao = SdkMetaDao(db);
        // Stale: denied a hair MORE than the TTL ago → must fall out.
        await dao.addSkippedDoctype('StaleReport', deniedAtMs: nowMs - ttl - 1);
        // Fresh: denied just now → must remain active.
        await dao.addSkippedDoctype('FreshCountry', deniedAtMs: nowMs);

        final active = await dao.readActiveSkippedDoctypes(nowMs: nowMs);
        expect(active, {'FreshCountry'});
        // Both rows still physically present — expiry is read-time only.
        expect(await db.query('permission_skip_doctypes'), hasLength(2));
        await db.close();
      },
    );

    test('TTL boundary is strict (denied_at_ms > nowMs - TTL)', () async {
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      // Exactly ON the boundary → NOT strictly greater → excluded.
      await dao.addSkippedDoctype('OnBoundary', deniedAtMs: nowMs - ttl);
      // One ms inside the window → included.
      await dao.addSkippedDoctype('JustInside', deniedAtMs: nowMs - ttl + 1);

      final active = await dao.readActiveSkippedDoctypes(nowMs: nowMs);
      expect(active, {'JustInside'});
      await db.close();
    });

    test('legacy rows stamped denied_at_ms = 0 are treated as expired',
        () async {
      // Self-heal path: `_ensureSkipTable` ALTER-adds `denied_at_ms` with a
      // DEFAULT 0 for legacy 1-column rows, which must read as expired so
      // the poisoned doctype is re-attempted.
      final db = await _freshDb();
      final dao = SdkMetaDao(db);
      // Force the row in with a 0 stamp (simulating the legacy default).
      await dao.addSkippedDoctype('LegacyPoison', deniedAtMs: 0);
      expect(await dao.readActiveSkippedDoctypes(nowMs: nowMs), isEmpty);
      await db.close();
    });
  });
}
