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

  // Defaults for tests that do not exercise the pullAndOverwriteLocal path.
  // Tests for that path override them with mocks.
  Future<Map<String, dynamic>> noopFetch(String dt, String name) async =>
      <String, dynamic>{};
  Future<void> noopApply(String dt, Map<String, dynamic> doc) async {}

  test('retry(outboxId) → row flips from failed to pending', () async {
    final id = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markFailed(
      id,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'timeout',
    );

    var pushCalls = 0;
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async {
        pushCalls++;
      },
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
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
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async => pushCalls++,
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
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
    await outbox.markFailed(
      idPerm,
      errorCode: ErrorCode.PERMISSION_DENIED,
      errorMessage: 'x',
    );
    final idNet = await outbox.insertPending(
      doctype: 'X',
      mobileUuid: 'u2',
      operation: OutboxOperation.insert,
      payload: '{}',
    );
    await outbox.markFailed(
      idNet,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'x',
    );

    var pushCalls = 0;
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async => pushCalls++,
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
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
    await outbox.markFailed(
      idA,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'x',
    );
    await outbox.markFailed(
      idB,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'x',
    );

    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async {},
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
    );
    await ctrl.retryAll(filterDoctypes: const ['A']);
    final a = await outbox.findById(idA);
    final b = await outbox.findById(idB);
    expect(a!.state, OutboxState.pending);
    expect(
      b!.state,
      OutboxState.failed,
      reason: 'B is not in the doctype filter',
    );
  });

  test('pause sets isPaused; resume clears', () async {
    final n = SyncStateNotifier();
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: n,
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async {},
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
    );
    await ctrl.pause();
    expect(n.value.isPaused, isTrue);
    await ctrl.resume();
    expect(n.value.isPaused, isFalse);
  });

  test(
    'resolveConflict pullAndOverwriteLocal: fetches, applies, marks done',
    () async {
      final id = await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-conflict',
        serverName: 'CUST-1',
        operation: OutboxOperation.update,
        payload: '{}',
      );
      await outbox.markConflict(id, errorMessage: 'mismatch');

      final fetched = <List<String>>[];
      final applied = <List<Object?>>[];

      Future<Map<String, dynamic>> fakeFetch(String dt, String name) async {
        fetched.add([dt, name]);
        return <String, dynamic>{
          'name': name,
          'modified': '2026-04-30 10:00:00.000000',
          'customer_name': 'Server Name',
        };
      }

      Future<void> fakeApply(String dt, Map<String, dynamic> doc) async {
        applied.add([dt, doc]);
      }

      final ctrl = SyncController(
        outboxDao: outbox,
        notifier: SyncStateNotifier(),
        runPull: () async => <String>{},
        runPullForDoctypes: (_) async {},
        runPush: () async {},
        fetchSingleDoc: fakeFetch,
        applySingleDoc: fakeApply,
      );

      await ctrl.resolveConflict(
        outboxId: id,
        action: ConflictAction.pullAndOverwriteLocal,
      );

      expect(fetched, [
        ['Customer', 'CUST-1'],
      ]);
      expect(applied.length, 1);
      expect(applied.first[0], 'Customer');
      expect((applied.first[1] as Map)['customer_name'], 'Server Name');
      final r = await outbox.findById(id);
      expect(r!.state, OutboxState.done);
    },
  );

  test(
    'resolveConflict pullAndOverwriteLocal: fetch failure leaves row in conflict',
    () async {
      final id = await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-conflict',
        serverName: 'CUST-1',
        operation: OutboxOperation.update,
        payload: '{}',
      );
      await outbox.markConflict(id, errorMessage: 'mismatch');

      var applyCalled = false;
      Future<Map<String, dynamic>> failingFetch(String dt, String name) async {
        throw Exception('network down');
      }

      Future<void> trackingApply(String dt, Map<String, dynamic> doc) async {
        applyCalled = true;
      }

      final ctrl = SyncController(
        outboxDao: outbox,
        notifier: SyncStateNotifier(),
        runPull: () async => <String>{},
        runPullForDoctypes: (_) async {},
        runPush: () async {},
        fetchSingleDoc: failingFetch,
        applySingleDoc: trackingApply,
      );

      await expectLater(
        ctrl.resolveConflict(
          outboxId: id,
          action: ConflictAction.pullAndOverwriteLocal,
        ),
        throwsException,
      );
      expect(applyCalled, isFalse);
      final r = await outbox.findById(id);
      expect(r!.state, OutboxState.conflict);
    },
  );

  test(
    'resolveConflict pullAndOverwriteLocal: serverName=null skips fetch and closes',
    () async {
      final id = await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u-conflict',
        // No serverName — INSERT that never reached the server.
        operation: OutboxOperation.insert,
        payload: '{}',
      );
      await outbox.markConflict(id, errorMessage: 'mismatch');

      var fetchCalled = false;
      Future<Map<String, dynamic>> trackingFetch(String dt, String name) async {
        fetchCalled = true;
        return <String, dynamic>{};
      }

      final ctrl = SyncController(
        outboxDao: outbox,
        notifier: SyncStateNotifier(),
        runPull: () async => <String>{},
        runPullForDoctypes: (_) async {},
        runPush: () async {},
        fetchSingleDoc: trackingFetch,
        applySingleDoc: noopApply,
      );

      await ctrl.resolveConflict(
        outboxId: id,
        action: ConflictAction.pullAndOverwriteLocal,
      );

      expect(fetchCalled, isFalse);
      final r = await outbox.findById(id);
      expect(r!.state, OutboxState.done);
    },
  );

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
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async => pushCalls++,
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
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
      runPull: () async {
        events.add('pull');
        return <String>{};
      },
      runPush: () async => events.add('push'),
      runPullForDoctypes: (s) async {
        events.add('pullFor:${s.join(",")}');
      },
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
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
    await outbox.markFailed(
      idF,
      errorCode: ErrorCode.NETWORK,
      errorMessage: 'x',
    );
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
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async {},
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
    );
    final errs = await ctrl.pendingErrors();
    expect(errs.length, 3);
    expect(errs.map((r) => r.id).toSet(), {idF, idC, idB});
  });

  test(
    'SIG-2: syncNow re-pulls deferred doctypes after push completes',
    () async {
      final calls = <String>[];
      final ctrl = SyncController(
        outboxDao: outbox,
        notifier: SyncStateNotifier(),
        runPull: () async {
          calls.add('pull');
          return {'Foo'};
        },
        runPush: () async {
          calls.add('push');
        },
        runPullForDoctypes: (s) async {
          calls.add('pullFor:${s.join(",")}');
        },
        fetchSingleDoc: noopFetch,
        applySingleDoc: noopApply,
      );
      await ctrl.syncNow();
      expect(calls, ['pull', 'push', 'pullFor:Foo']);
    },
  );

  test('SIG-2: syncNow does NOT re-pull when nothing was deferred', () async {
    final calls = <String>[];
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async {
        calls.add('pull');
        return <String>{};
      },
      runPush: () async {
        calls.add('push');
      },
      runPullForDoctypes: (_) async {
        calls.add('pullFor');
      },
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
    );
    await ctrl.syncNow();
    expect(calls, ['pull', 'push']);
  });

  test(r'state$ stream relays notifier changes', () async {
    final n = SyncStateNotifier();
    final ctrl = SyncController(
      outboxDao: outbox,
      notifier: n,
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: () async {},
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
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
