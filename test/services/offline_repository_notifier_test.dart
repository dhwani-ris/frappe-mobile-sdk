import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode_notifier.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('OfflineRepository reads mode through notifier', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final notifier = OfflineModeNotifier(
      const OfflineMode(enabled: true, isPersisted: true),
    );
    final repo = OfflineRepository(
      db,
      offlineModeNotifier: notifier,
      client: FrappeClient('http://localhost'),
    );

    // enabled=true → getDirtyDocumentsByDoctype returns local rows (empty list).
    final dirty1 = await repo.getDirtyDocumentsByDoctype('Customer');
    expect(dirty1, isEmpty);
    expect(repo.offlineMode.enabled, isTrue);

    // Flip to online mode → getter reflects immediately.
    notifier.value = const OfflineMode(enabled: false, isPersisted: true);
    expect(repo.offlineMode.enabled, isFalse);

    // enabled=false → short-circuits to empty immediately.
    final dirty2 = await repo.getDirtyDocumentsByDoctype('Customer');
    expect(dirty2, isEmpty);
  });
}
