import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/entities/doctype_meta_entity.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late FrappeSDK emptySdk;
  late FrappeSDK sdkWithSurvey;

  setUp(() async {
    final emptyDb = await AppDatabase.inMemoryDatabase();
    emptySdk = FrappeSDK.forTesting('https://fake.test', emptyDb);

    final surveyDb = await AppDatabase.inMemoryDatabase();
    await surveyDb.doctypeMetaDao.insertDoctypeMeta(
      DoctypeMetaEntity(
        doctype: 'Survey Form',
        modified: null,
        serverModifiedAt: null,
        isMobileForm: true,
        metaJson: '{}',
        groupName: 'Survey',
        sortOrder: 0,
      ),
    );
    sdkWithSurvey = FrappeSDK.forTesting('https://fake.test', surveyDb);
  });

  testWidgets('shows empty state when no groups configured', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MobileHomeScreen(sdk: emptySdk, appTitle: 'TestApp'),
    ));
    // pumpAndSettle() cannot be used here: MobileHomeScreen._load() calls
    // sqflite_ffi which runs on real OS isolates outside Flutter's test
    // scheduler. pumpAndSettle() only drains microtasks/timers managed by
    // that scheduler and would hang indefinitely waiting for I/O that it
    // can never advance. runAsync() yields to the real event loop so the
    // sqflite future resolves, then pump() triggers the setState rebuild.
    await tester.runAsync(() async {
      await emptySdk.meta.getMobileFormGroups();
    });
    await tester.pump();
    expect(find.textContaining('No forms configured'), findsOneWidget);
  });

  testWidgets('renders group name and doctype name', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MobileHomeScreen(sdk: sdkWithSurvey, appTitle: 'TestApp'),
    ));
    // pumpAndSettle() cannot be used here: MobileHomeScreen._load() calls
    // sqflite_ffi which runs on real OS isolates outside Flutter's test
    // scheduler and would cause pumpAndSettle to hang indefinitely.
    // runAsync() yields to the real event loop so the sqflite futures resolve.
    // We await all the operations _load() performs (groups + per-doctype
    // document query) so the widget's internal future has completed before
    // we pump the rebuild.
    await tester.runAsync(() async {
      final groups = await sdkWithSurvey.meta.getMobileFormGroups();
      for (final doctype in groups.values.expand((l) => l)) {
        await sdkWithSurvey.repository.getDocumentsByDoctype(doctype);
      }
    });
    await tester.pump();
    expect(find.text('Survey'), findsOneWidget);
    expect(find.text('Survey Form'), findsOneWidget);
  });

  testWidgets('shows app title in AppBar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MobileHomeScreen(sdk: emptySdk, appTitle: 'My App'),
    ));
    await tester.pump();
    expect(find.text('My App'), findsOneWidget);
  });
}
