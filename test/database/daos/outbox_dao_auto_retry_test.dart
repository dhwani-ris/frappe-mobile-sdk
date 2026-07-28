// Fix B / T-B7 — OutboxDao.resetTransientFailedToPending + resetToPending.
//
// resetTransientFailedToPending flips `failed` rows whose error_code is in the
// transient set {NETWORK, TIMEOUT, AUTH, UNKNOWN} and whose `attempts` is under
// the cap back to `pending`, clearing the error fields and bumping the per-row
// auto-retry counter. Everything else (VALIDATION / MANDATORY / PERMISSION_DENIED
// / LINK_EXISTS / TIMESTAMP_MISMATCH / NULL code / at-or-over cap) stays failed.
// resetToPending is the user-initiated retry: it restores the full budget.
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
  var seq = 0;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final stmt in systemTablesDDL()) {
      await db.execute(stmt);
    }
    dao = OutboxDao(db);
    seq = 0;
  });

  tearDown(() async => db.close());

  // Creates a `failed` row with the given error_code (or NULL) and an optional
  // pre-seeded attempts counter. Returns the row id.
  Future<int> failedRow(ErrorCode? code, {int attempts = 0}) async {
    final id = await dao.insertPending(
      doctype: 'X',
      mobileUuid: 'u${seq++}',
      operation: OutboxOperation.insert,
    );
    if (code != null) {
      await dao.markFailed(id, errorCode: code, errorMessage: 'boom');
    } else {
      // A `failed` row that predates error-code capture — code stays NULL.
      await db.update(
        'outbox',
        {'state': OutboxState.failed.wireName},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    if (attempts != 0) {
      await db.update(
        'outbox',
        {'attempts': attempts},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    return id;
  }

  test(
    'flips every transient-coded failed row to pending, clears error, bumps attempts',
    () async {
      final ids = <int>[
        await failedRow(ErrorCode.NETWORK),
        await failedRow(ErrorCode.TIMEOUT),
        await failedRow(ErrorCode.AUTH),
        await failedRow(ErrorCode.UNKNOWN),
      ];

      final flipped = await dao.resetTransientFailedToPending(maxAttempts: 5);
      expect(flipped, 4, reason: 'all four transient codes are requeued');

      for (final id in ids) {
        final row = (await dao.findById(id))!;
        expect(row.state, OutboxState.pending);
        expect(row.errorCode, isNull);
        expect(row.errorMessage, isNull);
        expect(row.attempts, 1, reason: 'auto-retry counter incremented once');
      }
    },
  );

  test('leaves server-rejection / null-code failed rows untouched', () async {
    final ids = <int>[
      await failedRow(ErrorCode.VALIDATION),
      await failedRow(ErrorCode.MANDATORY),
      await failedRow(ErrorCode.PERMISSION_DENIED),
      await failedRow(ErrorCode.LINK_EXISTS),
      await failedRow(ErrorCode.TIMESTAMP_MISMATCH),
      await failedRow(null),
    ];

    final flipped = await dao.resetTransientFailedToPending(maxAttempts: 5);
    expect(flipped, 0, reason: 'none of these are transient');

    for (final id in ids) {
      final row = (await dao.findById(id))!;
      expect(row.state, OutboxState.failed);
      expect(row.attempts, 0);
    }
  });

  test('a mixed batch flips only the transient rows and returns that count', () async {
    await failedRow(ErrorCode.NETWORK);
    await failedRow(ErrorCode.AUTH);
    await failedRow(ErrorCode.VALIDATION);
    await failedRow(ErrorCode.PERMISSION_DENIED);

    final flipped = await dao.resetTransientFailedToPending(maxAttempts: 5);
    expect(flipped, 2);
    expect(
      (await dao.findByState(OutboxState.pending)).length,
      2,
      reason: 'exactly the two transient rows moved to pending',
    );
    expect((await dao.findByState(OutboxState.failed)).length, 2);
  });

  test('does not flip a row at or over the attempt cap', () async {
    final atCap = await failedRow(ErrorCode.NETWORK, attempts: 2);
    final underCap = await failedRow(ErrorCode.NETWORK, attempts: 1);

    final flipped = await dao.resetTransientFailedToPending(maxAttempts: 2);
    expect(flipped, 1, reason: 'only the under-cap row is eligible');

    expect((await dao.findById(atCap))!.state, OutboxState.failed);
    expect((await dao.findById(atCap))!.attempts, 2);
    expect((await dao.findById(underCap))!.state, OutboxState.pending);
    expect((await dao.findById(underCap))!.attempts, 2);
  });

  test('resetToPending (user retry) zeroes attempts and clears the error', () async {
    final id = await failedRow(ErrorCode.NETWORK, attempts: 3);

    await dao.resetToPending(id);

    final row = (await dao.findById(id))!;
    expect(row.state, OutboxState.pending);
    expect(row.attempts, 0, reason: 'user retry restores the full auto-retry budget');
    expect(row.errorCode, isNull);
    expect(row.errorMessage, isNull);
  });
}
