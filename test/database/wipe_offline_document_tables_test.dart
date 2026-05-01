import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('wipeOfflineDocumentTables drops docs__* and clears queues', () async {
    final db = await AppDatabase.inMemoryDatabase();

    await db.rawDatabase.execute(
      'CREATE TABLE docs__customer (mobile_uuid TEXT, server_name TEXT)',
    );
    await db.rawDatabase.execute(
      'CREATE TABLE docs__contact (mobile_uuid TEXT)',
    );
    await db.rawDatabase.insert('docs__customer', {
      'mobile_uuid': 'u1',
      'server_name': 'CUST-1',
    });
    await db.rawDatabase.insert('outbox', {
      'doctype': 'Customer',
      'mobile_uuid': 'u1',
      'operation': 'create',
      'state': 'pending',
      'created_at': 1,
    });
    await db.rawDatabase.insert('pending_attachments', {
      'parent_uuid': 'u1',
      'parent_doctype': 'Customer',
      'parent_fieldname': 'attachment',
      'local_path': '/tmp/x',
      'state': 'pending',
      'created_at': 1,
    });
    await db.rawDatabase.insert('link_options', {
      'doctype': 'Customer',
      'name': 'CUST-1',
      'lastUpdated': 1,
    });

    await db.wipeOfflineDocumentTables();

    final docTables = await db.rawDatabase.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'docs__%'",
    );
    expect(docTables, isEmpty);

    final outbox = await db.rawDatabase.rawQuery('SELECT 1 FROM outbox');
    expect(outbox, isEmpty);
    final attach = await db.rawDatabase.rawQuery(
      'SELECT 1 FROM pending_attachments',
    );
    expect(attach, isEmpty);
    final links = await db.rawDatabase.rawQuery('SELECT 1 FROM link_options');
    expect(links, isEmpty);

    // Preserved tables — these should still be queryable.
    final sdkMeta = await db.rawDatabase.rawQuery('SELECT 1 FROM sdk_meta');
    expect(sdkMeta, isNotEmpty); // singleton row
    // Querying others must not throw.
    await db.rawDatabase.rawQuery('SELECT 1 FROM doctype_meta LIMIT 0');
    await db.rawDatabase.rawQuery('SELECT 1 FROM auth_tokens LIMIT 0');
    await db.rawDatabase.rawQuery('SELECT 1 FROM doctype_permission LIMIT 0');

    await db.close();
  });
}
