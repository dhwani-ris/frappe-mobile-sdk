import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao dao;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await db.execute('''
      CREATE TABLE outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        doctype TEXT NOT NULL,
        mobile_uuid TEXT NOT NULL,
        operation TEXT NOT NULL,
        state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        error_code TEXT,
        error_message TEXT
      )
    ''');
    dao = OutboxDao(db);
  });

  tearDown(() async => db.close());

  Future<List<Map<String, Object?>>> rows() async {
    return db.query('outbox', orderBy: 'created_at ASC, id ASC');
  }

  test('insert with no existing → fresh INSERT row', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    final rs = await rows();
    expect(rs.length, 1);
    expect(rs[0]['operation'], 'INSERT');
    expect(rs[0]['state'], 'pending');
  });

  test('INSERT then INSERT → keeps one row', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    final rs = await rows();
    expect(rs.length, 1);
  });

  test('INSERT then UPDATE → keeps INSERT, resets to pending', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    await dao.markFailed(1, errorCode: ErrorCode.NETWORK, errorMessage: 'y');
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    final rs = await rows();
    expect(rs.length, 1);
    expect(rs[0]['operation'], 'INSERT');
    expect(rs[0]['state'], 'pending');
    expect(rs[0]['error_code'], isNull);
    expect(rs[0]['error_message'], isNull);
  });

  test('UPDATE then UPDATE → collapses, resets to pending', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    await dao.markFailed(1, errorCode: ErrorCode.NETWORK, errorMessage: 'y');
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    final rs = await rows();
    expect(rs.length, 1);
    expect(rs[0]['operation'], 'UPDATE');
    expect(rs[0]['state'], 'pending');
  });

  test('INSERT then DELETE → cancels INSERT, no DELETE row', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    final result = await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.delete,
    );
    expect(result, RecordSaveResult.cancelledLocally);
    final rs = await rows();
    expect(rs, isEmpty);
  });

  test('UPDATE then DELETE → cancels UPDATE, enqueues DELETE', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    final result = await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.delete,
    );
    expect(result, RecordSaveResult.enqueued);
    final rs = await rows();
    expect(rs.length, 1);
    expect(rs[0]['operation'], 'DELETE');
  });

  test('in_flight UPDATE then save → does not collapse, fresh row', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    await dao.markInFlight(1);
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    final rs = await rows();
    expect(rs.length, 2);
    expect(rs[0]['state'], 'in_flight');
    expect(rs[1]['state'], 'pending');
  });

  test('SUBMIT after INSERT enqueues both ordered', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.submit,
    );
    final rs = await rows();
    expect(rs.length, 2);
    expect(rs[0]['operation'], 'INSERT');
    expect(rs[1]['operation'], 'SUBMIT');
    expect(rs[1]['created_at'], greaterThan(rs[0]['created_at'] as int));
  });

  test('cancelPendingFor wipes all collapsable rows for uuid', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.submit,
    );
    await dao.cancelPendingFor(doctype: 'Customer', mobileUuid: 'u1');
    final rs = await rows();
    expect(rs, isEmpty);
  });

  test('cancelPendingFor leaves in_flight rows alone', () async {
    await dao.recordSave(
      doctype: 'Customer',
      mobileUuid: 'u1',
      operation: OutboxOperation.update,
    );
    await dao.markInFlight(1);
    await dao.cancelPendingFor(doctype: 'Customer', mobileUuid: 'u1');
    final rs = await rows();
    expect(rs.length, 1);
    expect(rs[0]['state'], 'in_flight');
  });
}
