import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _customerMeta() => DocTypeMeta(
      name: 'Customer',
      fields: [
        DocField(fieldname: 'customer_name', fieldtype: 'Data', label: 'N'),
      ],
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<FrappeSDK> buildSdk(AppDatabase db) async {
    return FrappeSDK.forTesting('https://fake.test', db);
  }

  test(
    'runV1ToV2MigrationIfNeeded returns false when schema_version >= 2',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      // Force schema_version=2 (already migrated).
      await db.rawDatabase
          .update('sdk_meta', {'schema_version': 2}, where: 'id=1');

      final sdk = await buildSdk(db);
      final ran = await sdk.runV1ToV2MigrationIfNeeded(
        isOnline: () async =>
            throw StateError('connectivity must not be probed'),
        metaFetcher: (_) async =>
            throw StateError('meta fetch must not happen'),
      );
      expect(ran, isFalse);
    },
  );

  test(
    'runV1ToV2MigrationIfNeeded throws MigrationNeedsNetworkException when offline',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      // Seed a dirty legacy row so the migration would otherwise have work.
      await db.rawDatabase.insert('documents', {
        'localId': 'u1',
        'doctype': 'Customer',
        'serverId': null,
        'status': 'dirty',
        'modified': 1,
        'dataJson': jsonEncode({'customer_name': 'X'}),
      });

      final sdk = await buildSdk(db);
      await expectLater(
        sdk.runV1ToV2MigrationIfNeeded(
          isOnline: () async => false,
          metaFetcher: (_) async => _customerMeta(),
        ),
        throwsA(isA<MigrationNeedsNetworkException>()),
      );

      // Migration must NOT have run.
      final row = await db.rawDatabase.query('sdk_meta', limit: 1);
      expect(row.first['schema_version'], 0);
      final out = await db.rawDatabase.query('outbox');
      expect(out, isEmpty);
    },
  );

  test(
    'runV1ToV2MigrationIfNeeded returns true and runs migration when online',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      await db.rawDatabase.insert('documents', {
        'localId': 'u-ok',
        'doctype': 'Customer',
        'serverId': null,
        'status': 'dirty',
        'modified': 1,
        'dataJson': jsonEncode({'customer_name': 'OK'}),
      });

      final sdk = await buildSdk(db);
      final ran = await sdk.runV1ToV2MigrationIfNeeded(
        isOnline: () async => true,
        metaFetcher: (dt) async => _customerMeta(),
      );
      expect(ran, isTrue);

      final row = await db.rawDatabase.query('sdk_meta', limit: 1);
      expect(row.first['schema_version'], 2);
      final docs = await db.rawDatabase.query('docs__customer');
      expect(docs.length, 1);
      expect(docs.first['mobile_uuid'], 'u-ok');
    },
  );
}
