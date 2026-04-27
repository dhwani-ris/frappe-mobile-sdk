import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
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
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
    dao = OutboxDao(db);
  });

  tearDown(() async => db.close());

  test('insertPending persists a row in pending state', () async {
    final id = await dao.insertPending(
      doctype: 'Customer',
      mobileUuid: 'abc',
      operation: OutboxOperation.insert,
      payload: '{"name":"X"}',
    );
    expect(id, greaterThan(0));
    final row = await dao.findById(id);
    expect(row!.state, OutboxState.pending);
    expect(row.operation, OutboxOperation.insert);
    expect(row.doctype, 'Customer');
    expect(row.retryCount, 0);
  });

  test('findPending returns rows ordered by created_at', () async {
    await dao.insertPending(
      doctype: 'A', mobileUuid: 'u1',
      operation: OutboxOperation.insert, payload: '{}',
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await dao.insertPending(
      doctype: 'A', mobileUuid: 'u2',
      operation: OutboxOperation.insert, payload: '{}',
      createdAt: DateTime.utc(2026, 1, 2),
    );
    final rows = await dao.findByState(OutboxState.pending);
    expect(rows.map((r) => r.mobileUuid).toList(), ['u1', 'u2']);
  });

  test('markInFlight → markDone happy path', () async {
    final id = await dao.insertPending(
      doctype: 'X', mobileUuid: 'u',
      operation: OutboxOperation.insert, payload: '{}',
    );
    await dao.markInFlight(id);
    expect((await dao.findById(id))!.state, OutboxState.inFlight);
    await dao.markDone(id, serverName: 'SRV-1');
    final done = await dao.findById(id);
    expect(done!.state, OutboxState.done);
    expect(done.serverName, 'SRV-1');
  });

  test('markFailed stores error_code + retry count bump', () async {
    final id = await dao.insertPending(
      doctype: 'X', mobileUuid: 'u',
      operation: OutboxOperation.update, payload: '{}',
    );
    await dao.markFailed(id,
        errorCode: ErrorCode.NETWORK, errorMessage: 'timeout');
    final r = await dao.findById(id);
    expect(r!.state, OutboxState.failed);
    expect(r.errorCode, ErrorCode.NETWORK);
    expect(r.retryCount, 1);
  });

  test('collapseInsert merges into existing pending INSERT for same mobile_uuid', () async {
    final id = await dao.insertPending(
      doctype: 'X', mobileUuid: 'u1',
      operation: OutboxOperation.insert, payload: '{"v":1}',
    );
    final collapsed = await dao.collapseOrInsert(
      doctype: 'X', mobileUuid: 'u1',
      operation: OutboxOperation.insert, payload: '{"v":2}',
    );
    expect(collapsed, id);
    final r = await dao.findById(id);
    expect(r!.payload, '{"v":2}');
    final all = await dao.findByState(OutboxState.pending);
    expect(all.length, 1);
  });

  test('collapse does not merge SUBMIT onto INSERT', () async {
    await dao.insertPending(
      doctype: 'X', mobileUuid: 'u1',
      operation: OutboxOperation.insert, payload: '{}',
    );
    final id2 = await dao.collapseOrInsert(
      doctype: 'X', mobileUuid: 'u1',
      operation: OutboxOperation.submit, payload: '{}',
    );
    final all = await dao.findByState(OutboxState.pending);
    expect(all.length, 2, reason: 'SUBMIT must be separate from INSERT');
    expect(all.map((r) => r.id), contains(id2));
  });

  test('pruneDone removes done rows older than retention', () async {
    final old = await dao.insertPending(
      doctype: 'X', mobileUuid: 'u',
      operation: OutboxOperation.insert, payload: '{}',
    );
    await dao.markDone(old, serverName: 'S');
    await db.rawUpdate(
      'UPDATE outbox SET last_attempt_at = ? WHERE id = ?',
      [DateTime.utc(2020).millisecondsSinceEpoch, old],
    );
    final n = await dao.pruneDone(olderThan: const Duration(days: 1));
    expect(n, 1);
    expect(await dao.findById(old), isNull);
  });

  test('countByState returns per-state counts', () async {
    await dao.insertPending(
      doctype: 'X', mobileUuid: 'a',
      operation: OutboxOperation.insert, payload: '{}',
    );
    final b = await dao.insertPending(
      doctype: 'X', mobileUuid: 'b',
      operation: OutboxOperation.insert, payload: '{}',
    );
    await dao.markFailed(b, errorCode: ErrorCode.VALIDATION, errorMessage: 'x');
    final counts = await dao.countByState();
    expect(counts[OutboxState.pending], 1);
    expect(counts[OutboxState.failed], 1);
  });

  test('resetInFlightOnStartup flips in_flight → pending', () async {
    final id = await dao.insertPending(
      doctype: 'X', mobileUuid: 'a',
      operation: OutboxOperation.insert, payload: '{}',
    );
    await dao.markInFlight(id);
    final n = await dao.resetInFlightToPending();
    expect(n, 1);
    expect((await dao.findById(id))!.state, OutboxState.pending);
  });
}
