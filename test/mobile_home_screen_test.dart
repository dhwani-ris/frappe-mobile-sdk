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
    // runAsync lets sqflite_ffi futures (real isolates) resolve, then pump rebuilds UI
    await tester.runAsync(() async {
      await emptySdk.meta.getMobileFormGroups(); // warm up
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('No forms configured'), findsOneWidget);
  });

  testWidgets('renders group name and doctype name', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MobileHomeScreen(sdk: sdkWithSurvey, appTitle: 'TestApp'),
    ));
    await tester.runAsync(() async {
      // Wait for _load() to complete by waiting on the underlying async ops
      await Future<void>.delayed(const Duration(milliseconds: 200));
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
