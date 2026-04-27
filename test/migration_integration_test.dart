import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/migrations/v1_to_v2.dart';
import 'package:frappe_mobile_sdk/src/models/doc_field.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/ui/screens/migration_blocked_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('initialize runs v1→v2 migration when schema_version=0', () async {
    final appDb = await AppDatabase.inMemoryDatabase();
    final raw = appDb.rawDatabase;

    // Seed legacy v1 documents row that survived an upgrade.
    await raw.insert('documents', {
      'localId': 'u1',
      'doctype': 'Customer',
      'serverId': null,
      'status': 'dirty',
      'modified': 1,
      'dataJson': jsonEncode({'customer_name': 'X'}),
    });

    final migration = V1ToV2Migration(
      db: raw,
      metaFetcher: (dt) async => DocTypeMeta(
        name: dt,
        fields: [
          DocField(
            fieldname: 'customer_name',
            fieldtype: 'Data',
            label: 'N',
          ),
        ],
      ),
    );
    final ran = await migration.run();
    expect(ran, isTrue);

    final row = await raw.query('sdk_meta');
    expect(row.first['schema_version'], 2);

    final out = await raw.query('outbox');
    expect(out.length, 1);
    expect(out.first['operation'], 'INSERT');
  });

  testWidgets(
    'MigrationBlockedScreen shows offline message and triggers retry',
    (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MigrationBlockedScreen(
            onRetry: () => retries++,
            isOnline: false,
          ),
        ),
      );
      expect(find.textContaining('Waiting for network'), findsOneWidget);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Retry'));
      await tester.pump();
      expect(retries, 1);
    },
  );

  testWidgets(
    'MigrationBlockedScreen shows online state when isOnline=true',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MigrationBlockedScreen(
            onRetry: () {},
            isOnline: true,
            lastError: 'sample error',
          ),
        ),
      );
      expect(find.textContaining('Updating local database'), findsOneWidget);
      expect(find.text('sample error'), findsOneWidget);
    },
  );
}
