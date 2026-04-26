import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('systemTablesDDL — executes cleanly on a fresh DB', () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      for (final stmt in systemTablesDDL()) {
        await db.execute(stmt);
      }
    });

    tearDown(() async => db.close());

    test('outbox table exists with expected columns', () async {
      final rows = await db.rawQuery('PRAGMA table_info(outbox)');
      final names = rows.map((r) => r['name'] as String).toSet();
      expect(names, containsAll(<String>{
        'id', 'doctype', 'mobile_uuid', 'server_name',
        'operation', 'payload', 'state',
        'retry_count', 'last_attempt_at',
        'error_message', 'error_code', 'created_at',
      }));
    });

    test('outbox indexes exist', () async {
      final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='outbox'",
      );
      final names = rows.map((r) => r['name'] as String).toSet();
      expect(names, contains('ix_outbox_state'));
      expect(names, contains('ix_outbox_uuid'));
    });

    test('pending_attachments table exists', () async {
      final rows =
          await db.rawQuery('PRAGMA table_info(pending_attachments)');
      final names = rows.map((r) => r['name'] as String).toSet();
      expect(names, containsAll(<String>{
        'id', 'parent_uuid', 'parent_doctype', 'parent_fieldname',
        'local_path', 'file_name', 'mime_type', 'is_private',
        'size_bytes', 'state', 'retry_count', 'last_attempt_at',
        'error_message', 'server_file_name', 'server_file_url',
        'created_at',
      }));
    });

    test('sdk_meta table exists and seeds row', () async {
      final rows =
          await db.rawQuery('PRAGMA table_info(sdk_meta)');
      final names = rows.map((r) => r['name'] as String).toSet();
      expect(names, containsAll(<String>{
        'schema_version', 'session_user_json', 'bootstrap_done',
      }));
      final data = await db.rawQuery('SELECT * FROM sdk_meta');
      expect(data, isNotEmpty,
          reason: 'systemTablesDDL should seed a singleton row');
    });
  });

  group('doctypeMetaExtensionsDDL — adds new columns on existing doctype_meta', () {
    late Database db;

    setUp(() async {
      db = await databaseFactory.openDatabase(inMemoryDatabasePath);
      // Seed a v1 doctype_meta like the current DoctypeMetaDao's schema.
      await db.execute('''
        CREATE TABLE doctype_meta (
          doctype TEXT PRIMARY KEY,
          meta_json TEXT NOT NULL,
          group_name TEXT,
          sort_order INTEGER DEFAULT 0
        )
      ''');
    });

    tearDown(() async => db.close());

    test('adds meta_watermark, dep_graph_json, last_ok_cursor, etc.', () async {
      for (final stmt in doctypeMetaExtensionsDDL()) {
        await db.execute(stmt);
      }
      final rows = await db.rawQuery('PRAGMA table_info(doctype_meta)');
      final names = rows.map((r) => r['name'] as String).toSet();
      expect(names, containsAll(<String>{
        'meta_watermark',
        'dep_graph_json',
        'last_ok_cursor',
        'last_pull_started_at',
        'last_pull_ok_at',
        'is_entry_point',
        'is_child_table',
        'record_count',
        'table_name',
      }));
    });
  });
}
