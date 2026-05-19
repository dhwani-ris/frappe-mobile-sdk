import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/doctype_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/parent_schema.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late DoctypeDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    final meta = DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'N'),
        DocField(fieldname: 'age', fieldtype: 'Int', label: 'A'),
      ],
    );
    for (final stmt in buildParentSchemaDDL(meta, tableName: 'docs__customer')) {
      await db.execute(stmt);
    }
    dao = DoctypeDao(db, tableName: 'docs__customer');
  });

  tearDown(() async => db.close());

  test('insert + findByMobileUuid round trip', () async {
    await dao.insert({
      'mobile_uuid': 'u1',
      'sync_status': 'dirty',
      'local_modified': 1000,
      'customer_name': 'ACME',
      'age': 10,
    });
    final row = await dao.findByMobileUuid('u1');
    expect(row, isNotNull);
    expect(row!['customer_name'], 'ACME');
    expect(row['age'], 10);
  });

  test('upsertByServerName — updates if exists', () async {
    await dao.insert({
      'mobile_uuid': 'u1', 'server_name': 'SRV-1',
      'sync_status': 'synced', 'local_modified': 1000,
      'customer_name': 'Old',
    });
    await dao.upsertByServerName('SRV-1', <String, Object?>{
      'customer_name': 'New',
      'sync_status': 'synced',
      'modified': '2026-01-01 00:00:00',
    });
    final row = await dao.findByServerName('SRV-1');
    expect(row!['customer_name'], 'New');
    expect(row['mobile_uuid'], 'u1', reason: 'mobile_uuid stays stable');
  });

  test('upsertByServerName — inserts when absent (generates mobile_uuid)', () async {
    await dao.upsertByServerName('SRV-NEW', <String, Object?>{
      'customer_name': 'Fresh',
      'sync_status': 'synced',
      'modified': '2026-01-01 00:00:00',
      'local_modified': 2000,
    });
    final row = await dao.findByServerName('SRV-NEW');
    expect(row, isNotNull);
    expect(row!['mobile_uuid'], isNotNull);
    expect(row['customer_name'], 'Fresh');
  });

  test('findByStatus filters correctly', () async {
    await dao.insert({
      'mobile_uuid': 'a', 'sync_status': 'dirty', 'local_modified': 1
    });
    await dao.insert({
      'mobile_uuid': 'b', 'sync_status': 'synced', 'local_modified': 2
    });
    final dirty = await dao.findByStatus('dirty');
    expect(dirty.length, 1);
    expect(dirty.first['mobile_uuid'], 'a');
  });

  test('updateByMobileUuid applies partial patch', () async {
    await dao.insert({
      'mobile_uuid': 'u1', 'sync_status': 'dirty', 'local_modified': 1,
      'customer_name': 'X',
    });
    await dao.updateByMobileUuid('u1', {'customer_name': 'Y'});
    final r = await dao.findByMobileUuid('u1');
    expect(r!['customer_name'], 'Y');
  });
}
