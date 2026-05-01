import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart'
    show applyV3ToV4Attachments;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v3 → v4 (attachments) adds top_parent_uuid + top_parent_doctype + '
      'index, backfills from parent_uuid/parent_doctype', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);

    // Reproduce the v4 pending_attachments shape (no top_parent_* columns).
    await db.execute('''
      CREATE TABLE pending_attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_uuid TEXT NOT NULL,
        parent_doctype TEXT NOT NULL,
        parent_fieldname TEXT NOT NULL,
        local_path TEXT NOT NULL,
        file_name TEXT,
        mime_type TEXT,
        is_private INTEGER NOT NULL DEFAULT 1,
        size_bytes INTEGER,
        state TEXT NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER,
        error_message TEXT,
        server_file_name TEXT,
        server_file_url TEXT,
        created_at INTEGER NOT NULL
      )
    ''');

    // Pre-existing row (only parent-level attaches existed pre-fix).
    await db.insert('pending_attachments', {
      'parent_uuid': 'p-1',
      'parent_doctype': 'Survey',
      'parent_fieldname': 'photo',
      'local_path': '/tmp/x.jpg',
      'state': 'pending',
      'created_at': 1,
    });

    await applyV3ToV4Attachments(db);

    final cols = await db.rawQuery("PRAGMA table_info('pending_attachments')");
    final names = cols.map((r) => r['name'] as String).toSet();
    expect(names.contains('top_parent_uuid'), isTrue);
    expect(names.contains('top_parent_doctype'), isTrue);

    final indexes = await db.rawQuery(
      "PRAGMA index_list('pending_attachments')",
    );
    expect(indexes.any((r) => r['name'] == 'ix_attach_top_parent'), isTrue);

    // Backfill: existing row has top_parent_* equal to its parent_*.
    final rows = await db.query('pending_attachments');
    expect(rows.first['top_parent_uuid'], 'p-1');
    expect(rows.first['top_parent_doctype'], 'Survey');

    await db.close();
  });

  test('v3 → v4 (attachments) is idempotent — re-running tolerates duplicate '
      'columns', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE pending_attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        parent_uuid TEXT NOT NULL,
        parent_doctype TEXT NOT NULL,
        parent_fieldname TEXT NOT NULL,
        local_path TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    await applyV3ToV4Attachments(db);
    // Second run must not throw.
    await applyV3ToV4Attachments(db);

    final cols = await db.rawQuery("PRAGMA table_info('pending_attachments')");
    final tpu = cols.where((r) => r['name'] == 'top_parent_uuid').toList();
    expect(tpu, hasLength(1));

    await db.close();
  });
}
