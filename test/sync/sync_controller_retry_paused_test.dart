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

  Future<void> noopApply(String dt, Map<String, dynamic> d) async {}
  Future<Map<String, dynamic>> noopFetch(String dt, String n) async => {};

  SyncController buildCtrl({Future<void> Function()? runPush}) {
    return SyncController(
      outboxDao: outbox,
      notifier: SyncStateNotifier(),
      runPull: () async => <String>{},
      runPullForDoctypes: (_) async {},
      runPush: runPush ?? () async {},
      fetchSingleDoc: noopFetch,
      applySingleDoc: noopApply,
    );
  }

  test(
    'retryPaused resets a paused row to pending and triggers a push drain',
    () async {
      final id = await outbox.insertPending(
        doctype: 'Sales Order',
        mobileUuid: 'uuid-submit',
        operation: OutboxOperation.submit,
      );
      await outbox.markPaused(
        id,
        errorCode: ErrorCode.PERMISSION_DENIED,
        errorMessage: 'Insufficient permissions',
      );

      final before = await outbox.findById(id);
      expect(before?.state, OutboxState.paused);

      var pushDrainCount = 0;
      final ctrl = buildCtrl(runPush: () async => pushDrainCount++);

      await ctrl.retryPaused(id);

      final after = await outbox.findById(id);
      expect(
        after?.state,
        OutboxState.pending,
        reason: 'retryPaused must reset the row to pending',
      );
      expect(
        pushDrainCount,
        1,
        reason: 'retryPaused must trigger a push drain',
      );
    },
  );

  test('retryPaused is a no-op for a non-existent id', () async {
    final ctrl = buildCtrl();
    await expectLater(ctrl.retryPaused(99999), completes);
  });
}
