import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/services/offline_transition_service.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test(
    'persisted=online + residue → forceExit drops docs__* and clears queues',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      await SdkMetaDao(
        db.rawDatabase,
      ).writeOfflineMode(enabled: false, setAtMs: 1);

      // Seed residue: a docs__* table, an outbox row, a pending attachment.
      await db.rawDatabase.execute(
        'CREATE TABLE docs__customer (mobile_uuid TEXT, server_name TEXT)',
      );
      await db.rawDatabase.insert('docs__customer', {
        'mobile_uuid': 'u1',
        'server_name': null,
      });
      await db.rawDatabase.insert('outbox', {
        'doctype': 'Customer',
        'mobile_uuid': 'u1',
        'operation': 'create',
        'state': 'pending',
        'created_at': 1,
      });
      await db.rawDatabase.insert('pending_attachments', {
        'parent_uuid': 'u1',
        'parent_doctype': 'Customer',
        'parent_fieldname': 'attachment',
        'local_path': '/tmp/x',
        'state': 'pending',
        'created_at': 1,
      });

      final sdk = FrappeSDK.forTesting('http://localhost', db);

      // Drive the transition directly. Drain via real (offline-mode-on)
      // SyncService will not actually push anything because the fake
      // FrappeClient at http://localhost has no server — the residue
      // counter still reads non-zero, so the service parks in
      // DrainFailed. forceExit then drops everything.
      final completer = sdk.offlineTransition.runDrainAndWipe();
      // Wait for DrainFailed to be reached.
      await sdk.offlineTransition.stream.firstWhere(
        (s) => s is TransitionDrainFailed,
      );
      await sdk.offlineTransition.forceExit();
      await completer;

      final remainingTables = await db.rawDatabase.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name LIKE 'docs__%'",
      );
      expect(remainingTables, isEmpty);
      final remainingOutbox = await db.rawDatabase.rawQuery(
        'SELECT 1 FROM outbox',
      );
      expect(remainingOutbox, isEmpty);
      final remainingAttach = await db.rawDatabase.rawQuery(
        'SELECT 1 FROM pending_attachments',
      );
      expect(remainingAttach, isEmpty);

      await sdk.dispose();
      await db.close();
    },
    timeout: const Timeout(Duration(seconds: 10)),
  );
}
