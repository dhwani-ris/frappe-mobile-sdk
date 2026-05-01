import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('fresh DB creates outbox, pending_attachments, sdk_meta', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    final raw = appDb.rawDatabase;
    final tbls = await raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final names = tbls.map((r) => r['name'] as String).toSet();
    expect(
      names,
      containsAll(<String>{'outbox', 'pending_attachments', 'sdk_meta'}),
    );
  });

  test('fresh DB has doctype_meta with v3 columns', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    final raw = appDb.rawDatabase;
    final cols = await raw.rawQuery('PRAGMA table_info(doctype_meta)');
    final names = cols.map((r) => r['name'] as String).toSet();
    expect(
      names,
      containsAll(<String>{
        'table_name',
        'meta_watermark',
        'dep_graph_json',
        'last_ok_cursor',
      }),
    );
  });

  test(
    'sdk_meta seeded with schema_version=0 awaiting data migration',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      final raw = appDb.rawDatabase;
      final rows = await raw.query('sdk_meta', limit: 1);
      expect(rows.first['schema_version'], 0);
    },
  );

  test(
    'clearAllData drops all app-owned tables, recreates schema, preserves SQLite internals',
    () async {
      final appDb = await AppDatabase.inMemoryDatabase();
      final raw = appDb.rawDatabase;

      // Seed every table that should be wiped — including a per-doctype
      // mirror AND a hypothetical future table that doesn't follow the
      // `docs__` prefix (the prefix-only approach would miss this; the
      // "drop everything app-owned" approach catches it).
      await raw.execute(
        'CREATE TABLE docs__test (mobile_uuid TEXT PRIMARY KEY, server_name TEXT)',
      );
      await raw.execute(
        'CREATE TABLE future_feature (id INTEGER PRIMARY KEY, payload TEXT)',
      );
      await raw.insert('docs__test', {
        'mobile_uuid': 'u-1',
        'server_name': 'T-1',
      });
      await raw.insert('future_feature', {
        'id': 1,
        'payload': 'leak-me-if-you-can',
      });
      await raw.insert('outbox', {
        'doctype': 'X',
        'mobile_uuid': 'u-2',
        'operation': 'insert',
        'state': 'pending',
        'created_at': 0,
      });
      await raw.insert('pending_attachments', {
        'parent_uuid': 'u-3',
        'parent_doctype': 'X',
        'parent_fieldname': 'f',
        'local_path': '/tmp/x',
        'is_private': 1,
        'state': 'pending',
        'created_at': 0,
      });
      await raw.update('sdk_meta', <String, Object?>{
        'session_user_json': '{"name":"alice"}',
        'bootstrap_done': 1,
      }, where: 'id = 1');

      await appDb.clearAllDataForTesting();

      // Both per-doctype AND non-prefixed app tables are dropped.
      final docsLeft = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='docs__test'",
      );
      expect(docsLeft, isEmpty);
      final futureLeft = await raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='future_feature'",
      );
      expect(futureLeft, isEmpty);

      // Base schema recreated — outbox/pending_attachments/sdk_meta exist
      // again and are empty/reset.
      expect((await raw.query('outbox')), isEmpty);
      expect((await raw.query('pending_attachments')), isEmpty);
      final meta = await raw.query('sdk_meta');
      expect(meta, hasLength(1));
      expect(meta.first['session_user_json'], isNull);
      expect(meta.first['bootstrap_done'], 0);
      // schema_version bumped to 2 so V1ToV2Migration skips on next call
      // (the now-empty `documents` table has nothing to migrate).
      expect(meta.first['schema_version'], 2);

      // Engine still functions — re-insert into a recreated table works.
      await raw.insert('outbox', {
        'doctype': 'Y',
        'mobile_uuid': 'u-99',
        'operation': 'insert',
        'state': 'pending',
        'created_at': 0,
      });
      expect((await raw.query('outbox')), hasLength(1));
    },
  );
}
