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
    expect(names, containsAll(<String>{
      'outbox', 'pending_attachments', 'sdk_meta',
    }));
  });

  test('fresh DB has doctype_meta with v3 columns', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    final raw = appDb.rawDatabase;
    final cols = await raw.rawQuery('PRAGMA table_info(doctype_meta)');
    final names = cols.map((r) => r['name'] as String).toSet();
    expect(names, containsAll(<String>{
      'table_name', 'meta_watermark', 'dep_graph_json', 'last_ok_cursor',
    }));
  });

  test('sdk_meta seeded with schema_version=0 awaiting data migration', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    final raw = appDb.rawDatabase;
    final rows = await raw.query('sdk_meta', limit: 1);
    expect(rows.first['schema_version'], 0);
  });
}
