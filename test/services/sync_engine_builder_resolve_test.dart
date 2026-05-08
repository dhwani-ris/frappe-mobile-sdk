import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
  });

  tearDown(() async => db.close());

  test('returns null when the docs__<target> table does not exist', () async {
    final out = await debugResolveServerNameFor(db, 'Territory', 'u1');
    expect(out, isNull);
  });

  test(
    'returns server_name when row exists with non-null server_name',
    () async {
      await db.execute('''
      CREATE TABLE docs__territory (
        mobile_uuid TEXT PRIMARY KEY,
        server_name TEXT,
        sync_status TEXT NOT NULL DEFAULT 'synced',
        local_modified INTEGER NOT NULL DEFAULT 0
      )
    ''');
      await db.insert('docs__territory', {
        'mobile_uuid': 'u1',
        'server_name': 'TER-001',
      });
      final out = await debugResolveServerNameFor(db, 'Territory', 'u1');
      expect(out, 'TER-001');
    },
  );

  test('returns null when row exists but server_name IS NULL', () async {
    await db.execute('''
      CREATE TABLE docs__territory (
        mobile_uuid TEXT PRIMARY KEY,
        server_name TEXT,
        sync_status TEXT NOT NULL DEFAULT 'dirty',
        local_modified INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.insert('docs__territory', {'mobile_uuid': 'u1'});
    final out = await debugResolveServerNameFor(db, 'Territory', 'u1');
    expect(out, isNull);
  });
}
