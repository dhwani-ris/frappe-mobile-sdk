import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('residue guard (P2)', () {
    test('persisted=online + residue → boot stays online '
        '(P3 transition runs separately from boot-mode resolver)', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.rawDatabase.execute(
        'CREATE TABLE docs__customer (mobile_uuid TEXT)',
      );
      final sdk = FrappeSDK.forTesting('http://localhost', db);

      final mode = await sdk.resolveBootModeForTesting(
        const OfflineMode(enabled: false, isPersisted: true),
      );
      expect(
        mode.enabled,
        isFalse,
        reason:
            'P3 removed the P2 guard — the transition handler '
            'is invoked from initialize() instead and runs the real '
            'drain/wipe before _initialMetaAndDataSync.',
      );

      await sdk.dispose();
      await db.close();
    });

    test('persisted=online + no residue → online', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);

      final mode = await sdk.resolveBootModeForTesting(
        const OfflineMode(enabled: false, isPersisted: true),
      );
      expect(mode.enabled, isFalse);

      await sdk.dispose();
      await db.close();
    });

    test('unpersisted + outbox row → offline', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.rawDatabase.execute(
        "INSERT INTO outbox (doctype, mobile_uuid, operation, state, created_at) "
        "VALUES ('Customer', 'uuid-1', 'create', 'pending', 1)",
      );
      final sdk = FrappeSDK.forTesting('http://localhost', db);

      final mode = await sdk.resolveBootModeForTesting(OfflineMode.fallback);
      expect(mode.enabled, isTrue);
      expect(mode.isPersisted, isFalse);

      await sdk.dispose();
      await db.close();
    });

    test('unpersisted + pending_attachments row → offline', () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.rawDatabase.insert('pending_attachments', {
        'parent_uuid': 'u1',
        'parent_doctype': 'Customer',
        'parent_fieldname': 'attachment',
        'local_path': '/tmp/x',
        'state': 'pending',
        'created_at': 1,
      });
      final sdk = FrappeSDK.forTesting('http://localhost', db);

      final mode = await sdk.resolveBootModeForTesting(OfflineMode.fallback);
      expect(mode.enabled, isTrue);
      expect(mode.isPersisted, isFalse);

      await sdk.dispose();
      await db.close();
    });

    test('unpersisted + no residue → online', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);
      final mode = await sdk.resolveBootModeForTesting(OfflineMode.fallback);
      expect(mode.enabled, isFalse);
      expect(mode.isPersisted, isFalse);
      await sdk.dispose();
      await db.close();
    });

    test('persisted=offline → offline (no override)', () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);
      final mode = await sdk.resolveBootModeForTesting(
        const OfflineMode(enabled: true, isPersisted: true),
      );
      expect(mode.enabled, isTrue);
      expect(mode.isPersisted, isTrue);
      await sdk.dispose();
      await db.close();
    });
  });
}
