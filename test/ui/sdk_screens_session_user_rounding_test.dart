// The SDK's own screens hand the signed-in user and the opt-in rounding to the
// form they open. Before, DocumentListScreen, FrappeFormRenderer and
// MobileHomeScreen never passed `sessionUser`, so a `__user` / `user_fullname`
// default on a new document resolved to null there, and FormScreen had no way
// to opt into `roundNumbersOnSave`.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/ui/form/form_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _user = SessionUser(
  name: 'field.user@example.com',
  fullName: 'Field User',
  roles: [],
  permissions: {},
  userDefaults: {},
  extras: {},
);

final _metaJson = {
  'name': 'Task',
  'fields': [
    {
      'fieldname': 'logged_by',
      'fieldtype': 'Data',
      'label': 'Logged By',
      'default': '__user',
    },
    {
      'fieldname': 'price',
      'fieldtype': 'Currency',
      'label': 'Price',
      'precision': '2',
    },
  ],
};

DocTypeMeta _meta() => DocTypeMeta.fromJson(
  Map<String, dynamic>.from(jsonDecode(jsonEncode(_metaJson))),
);

Future<FrappeSDK> _sdk() async {
  final db = await AppDatabase.inMemoryDatabase();
  await db.doctypeMetaDao.insertDoctypeMeta(
    DoctypeMetaEntity(
      doctype: 'Task',
      isMobileForm: true,
      metaJson: jsonEncode(_metaJson),
      groupName: 'Work',
      sortOrder: 0,
    ),
  );
  final sdk = FrappeSDK.forTesting(
    'https://example.test',
    db,
    httpClient: MockClient((_) async => http.Response('{"message": {}}', 200)),
  );
  await sdk.sessionUserService.set(_user);
  return sdk;
}

/// Real-time hops plus pumps until [until] holds (sqflite ffi runs on real
/// isolates).
Future<void> _settle(WidgetTester tester, {bool Function()? until}) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (i >= 3 && (until?.call() ?? false)) break;
  }
}

class _FakeResolver extends Fake implements UnifiedResolver {
  @override
  Future<QueryResult<Map<String, Object?>>> resolve({
    required String doctype,
    List<List> filters = const [],
    List<List> orFilters = const [],
    String? orderBy,
    int page = 0,
    int pageSize = 50,
    bool includeFailed = false,
  }) async => QueryResult.ofRows(const [], pageSize, const {});
}

class _OfflineSync extends Fake implements SyncService {
  @override
  Future<bool> isOnline() async => false;
}

class _FakeMetaService extends Fake implements MetaService {}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('FrappeFormRenderer', () {
    testWidgets('renderForm resolves a __user default for the signed-in user', (
      tester,
    ) async {
      final sdk = (await tester.runAsync(_sdk))!;
      final form =
          (await tester.runAsync(
                () => FrappeFormRenderer(sdk: sdk).renderForm('Task'),
              ))!
              as FrappeFormBuilder;
      expect(form.sessionUser, _user);
      expect(form.roundNumbersOnSave, isFalse, reason: 'off by default');

      await tester.pumpWidget(MaterialApp(home: Scaffold(body: form)));
      await _settle(tester);
      expect(find.text('field.user@example.com'), findsOneWidget);
    });

    testWidgets('renderForm can opt into roundNumbersOnSave', (tester) async {
      final sdk = (await tester.runAsync(_sdk))!;
      final form =
          (await tester.runAsync(
                () => FrappeFormRenderer(
                  sdk: sdk,
                ).renderForm('Task', roundNumbersOnSave: true),
              ))!
              as FrappeFormBuilder;
      expect(form.roundNumbersOnSave, isTrue);
    });

    testWidgets(
      'navigateToForm hands the user and the rounding to FormScreen',
      (tester) async {
        final sdk = (await tester.runAsync(_sdk))!;
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                ctx = c;
                return const Scaffold(body: Text('HOME'));
              },
            ),
          ),
        );
        await tester.runAsync(
          () => FrappeFormRenderer(
            sdk: sdk,
          ).navigateToForm(ctx, 'Task', roundNumbersOnSave: true),
        );
        await _settle(
          tester,
          until: () => find.byType(FormScreen).evaluate().isNotEmpty,
        );
        final screen = tester.widget<FormScreen>(find.byType(FormScreen));
        expect(screen.sessionUser, _user);
        expect(screen.roundNumbersOnSave, isTrue);
      },
    );
  });

  group('FormScreen.roundNumbersOnSave', () {
    late AppDatabase appDb;
    late OfflineRepository repo;

    setUp(() async {
      appDb = await AppDatabase.inMemoryDatabase();
      repo = OfflineRepository(
        appDb,
        localWriter: LocalWriter(appDb.rawDatabase, (_) async => _meta()),
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        metaFetcher: (_) async => _meta(),
      );
    });

    tearDown(() async => appDb.close());

    testWidgets('legacy: reaches the form builder, off by default', (
      tester,
    ) async {
      for (final round in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: FormScreen(
              key: ValueKey(round),
              meta: _meta(),
              repository: repo,
              roundNumbersOnSave: round,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<FrappeFormBuilder>(find.byType(FrappeFormBuilder))
              .roundNumbersOnSave,
          round,
        );
      }
      expect(
        FormScreen(meta: _meta(), repository: repo).roundNumbersOnSave,
        isFalse,
      );
    });

    testWidgets('reactive: the controller FormScreen creates rounds at save', (
      tester,
    ) async {
      final controllers = <bool, FormController>{};
      for (final round in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: FormScreen(
              key: ValueKey(round),
              meta: _meta(),
              repository: repo,
              mode: FormBuilderMode.reactive,
              initialData: const {'price': 12.3456},
              roundNumbersOnSave: round,
              onControllerReady: (c) => controllers[round] = c,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          controllers[round]!.buildSubmitData()['price'],
          round ? 12.35 : 12.3456,
        );
      }
    });

    testWidgets('reactive: the controller FormScreen creates gets the user', (
      tester,
    ) async {
      FormController? controller;
      await tester.pumpWidget(
        MaterialApp(
          home: FormScreen(
            meta: _meta(),
            repository: repo,
            mode: FormBuilderMode.reactive,
            sessionUser: _user,
            onControllerReady: (c) => controller = c,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        controller!.buildSubmitData()['logged_by'],
        'field.user@example.com',
      );
    });
  });

  group('DocumentListScreen', () {
    late AppDatabase appDb;
    late OfflineRepository repo;

    setUp(() async {
      appDb = await AppDatabase.inMemoryDatabase();
      repo = OfflineRepository(
        appDb,
        localWriter: LocalWriter(appDb.rawDatabase, (_) async => _meta()),
        offlineMode: const OfflineMode(enabled: true, isPersisted: true),
        metaFetcher: (_) async => _meta(),
      );
      await repo.ensureSchemaForClosure(
        metas: {'Task': _meta()},
        childDoctypes: const {},
      );
    });

    tearDown(() async => appDb.close());

    testWidgets('the form it opens gets the user and the rounding', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentListScreen(
            doctype: 'Task',
            meta: _meta(),
            repository: repo,
            resolver: _FakeResolver(),
            syncService: _OfflineSync(),
            metaService: _FakeMetaService(),
            sessionUser: _user,
            roundNumbersOnSave: true,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(FloatingActionButton));
      await _settle(
        tester,
        until: () => find.byType(FormScreen).evaluate().isNotEmpty,
      );
      final screen = tester.widget<FormScreen>(find.byType(FormScreen));
      expect(screen.sessionUser, _user);
      expect(screen.roundNumbersOnSave, isTrue);
    });
  });

  testWidgets(
    'MobileHomeScreen hands the signed-in user to the list it opens',
    (tester) async {
      final sdk = (await tester.runAsync(_sdk))!;
      await tester.pumpWidget(
        MaterialApp(
          home: MobileHomeScreen(sdk: sdk, appTitle: 'Demo'),
        ),
      );
      await _settle(
        tester,
        until: () => find.text('Task').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Task'));
      await _settle(
        tester,
        until: () => find.byType(DocumentListScreen).evaluate().isNotEmpty,
      );
      final list = tester.widget<DocumentListScreen>(
        find.byType(DocumentListScreen),
      );
      expect(list.sessionUser, _user);
    },
  );

  testWidgets('a child-table row form gets the user for its own defaults', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FrappeFormBuilder(
            meta: DocTypeMeta(
              name: 'Parent',
              fields: [
                DocField(
                  fieldname: 'rows',
                  fieldtype: 'Table',
                  label: 'Rows',
                  options: 'Row',
                ),
              ],
            ),
            sessionUser: _user,
            roundNumbersOnSave: true,
            getMeta: (_) async => DocTypeMeta(
              name: 'Row',
              isTable: true,
              fields: [
                DocField(
                  fieldname: 'checked_by',
                  fieldtype: 'Data',
                  label: 'Checked By',
                  defaultValue: '__user',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add Row'));
    await tester.pumpAndSettle();
    final rowForm = tester
        .widgetList<FrappeFormBuilder>(find.byType(FrappeFormBuilder))
        .last;
    expect(rowForm.meta.name, 'Row');
    expect(rowForm.sessionUser, _user);
    expect(rowForm.roundNumbersOnSave, isTrue);
    expect(find.text('field.user@example.com'), findsOneWidget);
  });
}
