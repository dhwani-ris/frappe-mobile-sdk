import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sync/pull_apply.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _meta() => DocTypeMeta(
  name: 'Customer',
  isTable: false,
  fields: [DocField(fieldname: 'customer_name', fieldtype: 'Data')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE docs__customer (
        mobile_uuid TEXT PRIMARY KEY,
        server_name TEXT,
        sync_status TEXT NOT NULL DEFAULT 'dirty',
        sync_error TEXT,
        error_code TEXT,
        sync_attempts INTEGER NOT NULL DEFAULT 0,
        last_attempt_at INTEGER,
        sync_op TEXT,
        push_base_payload TEXT,
        docstatus INTEGER NOT NULL DEFAULT 0,
        modified TEXT,
        local_modified INTEGER NOT NULL,
        pulled_at INTEGER,
        customer_name TEXT
      )
    ''');
  });

  tearDown(() async => db.close());

  test('PullApply skips rows with sync_status=deleted', () async {
    await db.insert('docs__customer', {
      'mobile_uuid': 'u1',
      'server_name': 'CUST-001',
      'sync_status': 'deleted',
      'sync_op': 'DELETE',
      'local_modified': 1,
      'customer_name': 'Acme-local',
    });
    await PullApply.applyPage(
      db: db,
      parentMeta: _meta(),
      parentTable: 'docs__customer',
      childMetasByFieldname: const {},
      rows: [
        {
          'name': 'CUST-001',
          'modified': '2026-05-08 10:00:00',
          'customer_name': 'Acme-server',
        },
      ],
    );
    final rs = await db.query('docs__customer');
    expect(
      rs.first['customer_name'],
      'Acme-local',
      reason: 'tombstoned row must NOT be resurrected by pull',
    );
    expect(rs.first['sync_status'], 'deleted');
  });

  test('PullApply also skips sync_status=blocked rows', () async {
    await db.insert('docs__customer', {
      'mobile_uuid': 'u1',
      'server_name': 'CUST-001',
      'sync_status': 'blocked',
      'sync_op': 'UPDATE',
      'local_modified': 1,
      'modified': '2026-05-01 10:00:00',
      'customer_name': 'Acme-local',
    });
    await PullApply.applyPage(
      db: db,
      parentMeta: _meta(),
      parentTable: 'docs__customer',
      childMetasByFieldname: const {},
      rows: [
        {
          'name': 'CUST-001',
          'modified': '2026-05-08 10:00:00',
          'customer_name': 'Acme-server',
        },
      ],
    );
    final rs = await db.query('docs__customer');
    expect(rs.first['customer_name'], 'Acme-local');
    expect(
      rs.first['sync_status'],
      'conflict',
      reason: 'server-advanced + locally-blocked → conflict',
    );
  });
}
