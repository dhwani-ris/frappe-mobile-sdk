import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<SyncService> makeSync(AppDatabase db) async {
    final client = FrappeClient('http://localhost');
    final repo = OfflineRepository(
      db,
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: client,
    );
    return SyncService(
      client,
      repo,
      db,
      getMobileUuid: () async => 'u',
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
    );
  }

  test('getPullPhase returns initial when no cursor exists', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final svc = await makeSync(db);
    expect(await svc.getPullPhase('Customer'), DoctypePullPhase.initial);
    await db.close();
  });

  test('getPullPhase returns resume when cursor has complete=false', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.doctypeMetaDao.upsertMetaJson('Customer', '{}');
    await db.doctypeMetaDao.setLastOkCursor(
      'Customer',
      '{"modified":"2026-01-01","name":"CUST-1","complete":false}',
    );
    final svc = await makeSync(db);
    expect(await svc.getPullPhase('Customer'), DoctypePullPhase.resume);
    await db.close();
  });

  test(
    'getPullPhase returns incremental when cursor has complete=true',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.doctypeMetaDao.upsertMetaJson('Customer', '{}');
      await db.doctypeMetaDao.setLastOkCursor(
        'Customer',
        '{"modified":"2026-01-01","name":"CUST-1","complete":true}',
      );
      final svc = await makeSync(db);
      expect(await svc.getPullPhase('Customer'), DoctypePullPhase.incremental);
      await db.close();
    },
  );

  test('getPullPhase returns initial on corrupted cursor JSON', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.doctypeMetaDao.upsertMetaJson('Customer', '{}');
    await db.doctypeMetaDao.setLastOkCursor('Customer', '{not valid json');
    final svc = await makeSync(db);
    expect(await svc.getPullPhase('Customer'), DoctypePullPhase.initial);
    await db.close();
  });

  test('getPullPhases bulk-fetches phases for many doctypes', () async {
    final db = await AppDatabase.inMemoryDatabase();
    await db.doctypeMetaDao.upsertMetaJson('Customer', '{}');
    await db.doctypeMetaDao.setLastOkCursor(
      'Customer',
      '{"modified":"2026-01-01","name":"CUST-1","complete":true}',
    );
    await db.doctypeMetaDao.upsertMetaJson('Supplier', '{}');
    await db.doctypeMetaDao.setLastOkCursor(
      'Supplier',
      '{"modified":"2026-01-01","name":"SUP-1","complete":false}',
    );

    final svc = await makeSync(db);
    final phases = await svc.getPullPhases(['Customer', 'Supplier', 'Item']);
    expect(phases, {
      'Customer': DoctypePullPhase.incremental,
      'Supplier': DoctypePullPhase.resume,
      'Item': DoctypePullPhase.initial,
    });
    await db.close();
  });
}
