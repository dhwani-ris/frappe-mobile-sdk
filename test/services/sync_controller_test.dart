import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/sync_controller.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late OutboxDao outbox;
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    outbox = OutboxDao(db);
  });
  tearDown(() async => db.close());

  test('retry(outboxId) → row flips from failed to pending', () async {
    final id = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markFailed(id,
        errorCode: ErrorCode.NETWORK, errorMessage: 'timeout');

    var pushCalls = 0;
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {},
      runPush: () async {
        pushCalls++;
      },
    );
    await ctrl.retry(id);
    final r = await outbox.findById(id);
    expect(r!.state, OutboxState.pending);
    expect(pushCalls, 1);
  });

  test('retry on done row is a no-op', () async {
    final id = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markDone(id, serverName: 'X-1');
    var pushCalls = 0;
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {},
      runPush: () async => pushCalls++,
    );
    await ctrl.retry(id);
    final r = await outbox.findById(id);
    expect(r!.state, OutboxState.done);
    expect(pushCalls, 0);
  });

  test('retryAll requeues failed/conflict/blocked into pending', () async {
    final idPerm = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u1',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markFailed(idPerm,
        errorCode: ErrorCode.PERMISSION_DENIED, errorMessage: 'x');
    final idNet = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u2',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markFailed(idNet,
        errorCode: ErrorCode.NETWORK, errorMessage: 'x');

    var pushCalls = 0;
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {},
      runPush: () async => pushCalls++,
    );
    await ctrl.retryAll();
    final net = await outbox.findById(idNet);
    final perm = await outbox.findById(idPerm);
    expect(net!.state, OutboxState.pending);
    expect(perm!.state, OutboxState.pending);
    expect(pushCalls, 1, reason: 'retryAll triggers a single push drain');
  });

  test('retryAll filterDoctypes scopes to listed doctypes only', () async {
    final idA = await outbox.insertPending(
      doctype: 'A',
      mobileUuid: 'a',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    final idB = await outbox.insertPending(
      doctype: 'B',
      mobileUuid: 'b',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markFailed(idA, errorCode: ErrorCode.NETWORK, errorMessage: 'x');
    await outbox.markFailed(idB, errorCode: ErrorCode.NETWORK, errorMessage: 'x');

    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {},
      runPush: () async {},
    );
    await ctrl.retryAll(filterDoctypes: const ['A']);
    final a = await outbox.findById(idA);
    final b = await outbox.findById(idB);
    expect(a!.state, OutboxState.pending);
    expect(b!.state, OutboxState.failed,
        reason: 'B is not in the doctype filter');
  });

  test('pause sets isPaused; resume clears', () async {
    final n = SyncStateNotifier();
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: n,
      runPull: () async {},
      runPush: () async {},
    );
    await ctrl.pause();
    expect(n.value.isPaused, isTrue);
    await ctrl.resume();
    expect(n.value.isPaused, isFalse);
  });

  test('resolveConflict pullAndOverwriteLocal → marks done', () async {
    final id = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.update,
      payload: '{}',
    );
    await db.update('outbox', {'server_name': 'X-1'},
        where: 'id=?', whereArgs: [id]);
    await outbox.markConflict(id, errorMessage: 'x');
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {},
      runPush: () async {},
    );
    await ctrl.resolveConflict(
      outboxId: id,
      action: ConflictAction.pullAndOverwriteLocal,
    );
    final r = await outbox.findById(id);
    expect(r!.state, OutboxState.done);
  });

  test('resolveConflict keepLocalAndRetry → flips to pending + push', () async {
    final id = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.update,
      payload: '{}',
    );
    await outbox.markConflict(id, errorMessage: 'x');
    var pushCalls = 0;
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {},
      runPush: () async => pushCalls++,
    );
    await ctrl.resolveConflict(
      outboxId: id,
      action: ConflictAction.keepLocalAndRetry,
    );
    final r = await outbox.findById(id);
    expect(r!.state, OutboxState.pending);
    expect(pushCalls, 1);
  });

  test('syncNow runs pull then push', () async {
    final events = <String>[];
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async => events.add('pull'),
      runPush: () async => events.add('push'),
    );
    await ctrl.syncNow();
    expect(events, ['pull', 'push']);
  });

  test('pendingErrors returns rows in failed/conflict/blocked', () async {
    final idF = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'f',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markFailed(idF, errorCode: ErrorCode.NETWORK, errorMessage: 'x');
    final idC = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'c',
      operation: OutboxOperation.update,
      payload: '{}',
    );
    await outbox.markConflict(idC, errorMessage: 'x');
    final idB = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'b',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markBlocked(idB, reason: 'parent unsynced');

    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {},
      runPush: () async {},
    );
    final errs = await ctrl.pendingErrors();
    expect(errs.length, 3);
    expect(errs.map((r) => r.id).toSet(), {idF, idC, idB});
  });

  test(r'state$ stream relays notifier changes', () async {
    final n = SyncStateNotifier();
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: n,
      runPull: () async {},
      runPush: () async {},
    );
    final emitted = <bool>[];
    final sub = ctrl.state$.listen((s) => emitted.add(s.isPaused));
    await ctrl.pause();
    await Future<void>.delayed(Duration.zero);
    await ctrl.resume();
    await Future<void>.delayed(Duration.zero);
    expect(emitted, [true, false]);
    await sub.cancel();
  });
}
