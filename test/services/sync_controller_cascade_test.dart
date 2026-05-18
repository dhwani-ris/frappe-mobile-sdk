// Adds coverage for the SyncController surfaces not exercised by the main
// `sync_controller_test.dart`: cancelInitialSync, previewDeleteCascade,
// acceptDeleteCascade, retryAll error-state filtering, and the
// best-effort branches of syncNow.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/outbox_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/outbox_row.dart';
import 'package:frappe_mobile_sdk/src/services/sync_controller.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state.dart';
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

  Future<Map<String, dynamic>> noopFetch(String dt, String n) async => {};
  Future<void> noopApply(String dt, Map<String, dynamic> d) async {}
  SyncController buildCtrl({
    SyncStateNotifier? notifier,
    Future<Set<String>> Function()? runPull,
    Future<void> Function()? runPush,
    Future<void> Function(Set<String>)? runPullForDoctypes,
  }) {
    return SyncController(
      outboxDao: outbox,
      notifier: notifier ?? SyncStateNotifier(),
      runPull: runPull ?? () async => <String>{},
      runPullForDoctypes: runPullForDoctypes ?? (_) async {},
      runPush: runPush ?? () async {},
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
    );
  }

  group('cancelInitialSync', () {
    test('flips isInitialSync to false on the notifier', () async {
      final notifier = SyncStateNotifier();
      notifier.value = SyncState.initial.copyWith(isInitialSync: true);
      final ctrl = buildCtrl(notifier: notifier);
      await ctrl.cancelInitialSync();
      expect(notifier.value.isInitialSync, isFalse);
    });
  });

  group('previewDeleteCascade', () {
    test('returns null for unknown id', () async {
      final ctrl = buildCtrl();
      expect(await ctrl.previewDeleteCascade(99999), isNull);
    });

    test('returns null when row is not failed(LINK_EXISTS)', () async {
      final id = await outbox.insertPending(
        doctype: 'X',
        mobileUuid: 'u',
        operation: OutboxOperation.delete,
      );
      await outbox.markFailed(
        id,
        errorCode: ErrorCode.NETWORK,
        errorMessage: 'oops',
      );
      final ctrl = buildCtrl();
      expect(await ctrl.previewDeleteCascade(id), isNull);
    });

    test('parses linked map into a DeleteCascadePlan', () async {
      final id = await outbox.insertPending(
        doctype: 'Customer',
        mobileUuid: 'u',
        operation: OutboxOperation.delete,
      );
      await outbox.markFailed(
        id,
        errorCode: ErrorCode.LINK_EXISTS,
        errorMessage: jsonEncode({
          'linked': {
            'Sales Invoice': ['SI-001', 'SI-002'],
            'Contact': ['CON-9'],
          },
        }),
      );
      final ctrl = buildCtrl();
      final plan = await ctrl.previewDeleteCascade(id);
      expect(plan, isNotNull);
      expect(plan!.rootOutboxId, id);
      expect(plan.blockedBy, hasLength(2));
      expect(plan.blockedBy['Sales Invoice'], ['SI-001', 'SI-002']);
      expect(plan.blockedBy['Contact'], ['CON-9']);
    });

    test(
      'returns empty blockedBy when error_message is missing/malformed',
      () async {
        final id = await outbox.insertPending(
          doctype: 'X',
          mobileUuid: 'u',
          operation: OutboxOperation.delete,
        );
        await outbox.markFailed(
          id,
          errorCode: ErrorCode.LINK_EXISTS,
          errorMessage: '{not valid json',
        );
        final ctrl = buildCtrl();
        final plan = await ctrl.previewDeleteCascade(id);
        expect(plan, isNotNull);
        expect(plan!.blockedBy, isEmpty);
      },
    );
  });

  group('acceptDeleteCascade', () {
    test('resets a LINK_EXISTS row to pending and triggers push', () async {
      final id = await outbox.insertPending(
        doctype: 'X',
        mobileUuid: 'u',
        operation: OutboxOperation.delete,
      );
      await outbox.markFailed(
        id,
        errorCode: ErrorCode.LINK_EXISTS,
        errorMessage: '{}',
      );
      var pushCalls = 0;
      final ctrl = buildCtrl(runPush: () async => pushCalls++);
      await ctrl.acceptDeleteCascade(id);

      expect((await outbox.findById(id))!.state, OutboxState.pending);
      expect(pushCalls, 1);
    });

    test('is a no-op when row is not LINK_EXISTS', () async {
      final id = await outbox.insertPending(
        doctype: 'X',
        mobileUuid: 'u',
        operation: OutboxOperation.delete,
      );
      await outbox.markFailed(
        id,
        errorCode: ErrorCode.NETWORK,
        errorMessage: 'oops',
      );
      var pushCalls = 0;
      final ctrl = buildCtrl(runPush: () async => pushCalls++);
      await ctrl.acceptDeleteCascade(id);

      // Row stays in failed; no push fired.
      expect((await outbox.findById(id))!.state, OutboxState.failed);
      expect(pushCalls, 0);
    });

    test('returns silently for unknown id', () async {
      var pushCalls = 0;
      final ctrl = buildCtrl(runPush: () async => pushCalls++);
      await ctrl.acceptDeleteCascade(99999);
      expect(pushCalls, 0);
    });
  });

  group('syncNow best-effort error swallow', () {
    test('continues to push even when runPull throws', () async {
      var pushCalls = 0;
      final ctrl = buildCtrl(
        runPull: () async => throw StateError('pull boom'),
        runPush: () async => pushCalls++,
      );
      await ctrl.syncNow();
      expect(pushCalls, 1);
    });

    test('swallows runPush errors (no throw propagates to caller)', () async {
      final ctrl = buildCtrl(
        runPush: () async => throw StateError('push boom'),
      );
      // Should NOT throw — syncNow is best-effort.
      await ctrl.syncNow();
    });

    test('swallows runPullForDoctypes errors after a deferred set', () async {
      var rePullCalls = 0;
      final ctrl = buildCtrl(
        runPull: () async => {'Customer'},
        runPullForDoctypes: (_) async {
          rePullCalls++;
          throw StateError('re-pull boom');
        },
      );
      await ctrl.syncNow();
      expect(rePullCalls, 1);
    });

    test('is a no-op when paused (no pull / no push)', () async {
      final notifier = SyncStateNotifier();
      var pullCalls = 0;
      var pushCalls = 0;
      final ctrl = buildCtrl(
        notifier: notifier,
        runPull: () async {
          pullCalls++;
          return <String>{};
        },
        runPush: () async => pushCalls++,
      );
      await ctrl.pause();
      await ctrl.syncNow();
      expect(pullCalls, 0);
      expect(pushCalls, 0);
    });
  });
}
