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
    );
    expect(id, greaterThan(0));
    final row = await dao.findById(id);
    expect(row!.state, OutboxState.pending);
    expect(row.operation, OutboxOperation.insert);
    expect(row.doctype, 'Customer');
  });

  test('findByState returns rows ordered by created_at', () async {
    await dao.insertPending(
      doctype: 'A',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
      createdAt: DateTime.utc(2026, 1, 1),
    );
    await dao.insertPending(
      doctype: 'A',
      mobileUuid: 'u2',
      operation: OutboxOperation.insert,
      createdAt: DateTime.utc(2026, 1, 2),
    );
    final rows = await dao.findByState(OutboxState.pending);
    expect(rows.map((r) => r.mobileUuid).toList(), ['u1', 'u2']);
  });

  test('markInFlight flips state to in_flight', () async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.insert,
    );
    await dao.markInFlight(id);
    expect((await dao.findById(id))!.state, OutboxState.inFlight);
  });

  test(
    'markDone deletes the row (outbox holds only owed-to-server work)',
    () async {
      final id = await dao.insertPending(
        doctype: 'X',
        mobileUuid: 'u',
        operation: OutboxOperation.insert,
      );
      await dao.markDone(id, serverName: 'SRV-1');
      expect(
        await dao.findById(id),
        isNull,
        reason: 'markDone deletes the row outright',
      );
    },
  );

  test('markFailed records error_code + error_message; state=failed', () async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.update,
    );
    await dao.markFailed(
      id,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'timeout',
    );
    final r = await dao.findById(id);
    expect(r!.state, OutboxState.failed);
    expect(r.errorCode, ErrorCode.NETWORK);
    expect(r.errorMessage, 'timeout');
  });

  test('markBlocked records reason and flips state to blocked', () async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.update,
    );
    await dao.markBlocked(id, reason: 'parent unresolved');
    final r = await dao.findById(id);
    expect(r!.state, OutboxState.blocked);
    expect(r.errorMessage, 'parent unresolved');
  });

  test(
    'markConflict flips state to conflict with TIMESTAMP_MISMATCH code',
    () async {
      final id = await dao.insertPending(
        doctype: 'X',
        mobileUuid: 'u',
        operation: OutboxOperation.update,
      );
      await dao.markConflict(id, errorMessage: 'server moved');
      final r = await dao.findById(id);
      expect(r!.state, OutboxState.conflict);
      expect(r.errorCode, ErrorCode.TIMESTAMP_MISMATCH);
    },
  );

  test('countByState returns per-state counts', () async {
    await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'a',
      operation: OutboxOperation.insert,
    );
    final b = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'b',
      operation: OutboxOperation.insert,
    );
    await dao.markFailed(b, errorCode: ErrorCode.VALIDATION, errorMessage: 'x');
    final counts = await dao.countByState();
    expect(counts[OutboxState.pending], 1);
    expect(counts[OutboxState.failed], 1);
  });

  test('resetInFlightToPending flips in_flight → pending', () async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'a',
      operation: OutboxOperation.insert,
    );
    await dao.markInFlight(id);
    final n = await dao.resetInFlightToPending();
    expect(n, 1);
    expect((await dao.findById(id))!.state, OutboxState.pending);
  });

  test('resetToPending clears error_code/error_message', () async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'a',
      operation: OutboxOperation.update,
    );
    await dao.markFailed(
      id,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'timeout',
    );
    await dao.resetToPending(id);
    final r = await dao.findById(id);
    expect(r!.state, OutboxState.pending);
    expect(r.errorCode, isNull);
    expect(r.errorMessage, isNull);
  });

  test(
    'findByMobileUuid returns rows for the right (doctype, uuid) only',
    () async {
      await dao.insertPending(
        doctype: 'A',
        mobileUuid: 'u1',
        operation: OutboxOperation.insert,
        createdAt: DateTime.utc(2026, 1, 1),
      );
      final id2 = await dao.insertPending(
        doctype: 'A',
        mobileUuid: 'u1',
        operation: OutboxOperation.update,
        createdAt: DateTime.utc(2026, 1, 2),
      );
      await dao.insertPending(
        doctype: 'A',
        mobileUuid: 'u2',
        operation: OutboxOperation.insert,
      );
      await dao.insertPending(
        doctype: 'B',
        mobileUuid: 'u1',
        operation: OutboxOperation.insert,
      );

      final rows = await dao.findByMobileUuid(doctype: 'A', mobileUuid: 'u1');
      expect(rows.length, 2);
      expect(rows.map((r) => r.operation).toList(), [
        OutboxOperation.insert,
        OutboxOperation.update,
      ]);
      expect(
        rows.last.id,
        id2,
        reason: 'rows are ordered created_at ASC, id ASC',
      );
    },
  );

  test(
    'hasActivePushFor returns true when pending or in_flight exists',
    () async {
      expect(await dao.hasActivePushFor('Customer'), isFalse);
      final id = await dao.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u',
        operation: OutboxOperation.insert,
      );
      expect(await dao.hasActivePushFor('Customer'), isTrue);
      await dao.markInFlight(id);
      expect(await dao.hasActivePushFor('Customer'), isTrue);
    },
  );
}
