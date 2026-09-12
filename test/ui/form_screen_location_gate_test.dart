import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocField _hidden(String n, String t) =>
    DocField(fieldname: n, fieldtype: t, hidden: true, readOnly: true);

/// Provisioned by mobile_control — the capture (and therefore the gate) applies.
DocTypeMeta _meta() => DocTypeMeta(
  name: 'Survey',
  fields: [
    _hidden(mobileCreatedAtField, 'Datetime'),
    _hidden(mobileLatitudeLongitudeField, 'Geolocation'),
    DocField(fieldname: 'village', fieldtype: 'Data', label: 'Village'),
  ],
);

/// A doctype on a server without mobile_control: nowhere to store a location,
/// so the gate must never fire.
DocTypeMeta _bare() => DocTypeMeta(
  name: 'Survey',
  fields: [DocField(fieldname: 'village', fieldtype: 'Data', label: 'Village')],
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

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
      metas: {'Survey': _meta()},
      childDoctypes: const {},
    );
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Widget host({
    required MobileCreationCapture capture,
    DocTypeMeta? meta,
    Document? document,
  }) => MaterialApp(
    home: Scaffold(
      body: FormScreen(
        meta: meta ?? _meta(),
        document: document,
        repository: repo,
        mode: FormBuilderMode.reactive,
        creationCapture: capture,
      ),
    ),
  );

  MobileCreationCapture captureWith(
    List<LocationReadiness> readings, {
    LocationReadiness afterRequest = LocationReadiness.ready,
    int? requestCounter,
  }) {
    var i = 0;
    return MobileCreationCapture(
      now: () => DateTime(2026, 8, 19, 10, 0, 0),
      readLocation: () async => 'GEO',
      checkReadiness: () async =>
          readings[i < readings.length ? i++ : readings.length - 1],
      requestPermission: () async => afterRequest,
    );
  }

  testWidgets('an askable denial blocks the form and offers the OS prompt', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(capture: captureWith([LocationReadiness.permissionDenied])),
    );
    await settle(tester);

    expect(find.byType(LocationRequiredBarrier), findsOneWidget);
    expect(find.text('Allow location'), findsOneWidget);
    // The form widgets stay in the tree behind the overlay — what matters is
    // that they are unreachable. `enterText` is NOT a valid probe for that: it
    // drives the field's state directly and bypasses hit-testing entirely, so
    // it "succeeds" through any barrier. A real tap does respect hit-testing.
    // A tap aimed at the field is swallowed rather than delivered.
    await tester.tap(find.byType(TextField), warnIfMissed: false);
    await settle(tester);
    expect(
      tester
          .widget<AbsorbPointer>(
            find.byKey(const Key('form_location_absorber')),
          )
          .absorbing,
      isTrue,
      reason: 'the form subtree is disabled, not merely covered',
    );
  });

  testWidgets('a blocked permission offers app settings, not the OS prompt', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(capture: captureWith([LocationReadiness.permissionBlocked])),
    );
    await settle(tester);

    expect(find.byType(LocationRequiredBarrier), findsOneWidget);
    expect(find.text('Open settings'), findsOneWidget);
    expect(
      find.text('Allow location'),
      findsNothing,
      reason: 'asking again cannot fix deniedForever',
    );
  });

  testWidgets('location services off offers the device location settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(capture: captureWith([LocationReadiness.serviceDisabled])),
    );
    await settle(tester);

    expect(find.text('Open location settings'), findsOneWidget);
  });

  testWidgets('granting through the barrier clears it and reveals the form', (
    tester,
  ) async {
    // First read blocks, and after the OS prompt the next read is ready.
    await tester.pumpWidget(
      host(
        capture: captureWith([
          LocationReadiness.permissionDenied,
          LocationReadiness.ready,
        ]),
      ),
    );
    await settle(tester);
    expect(find.byType(LocationRequiredBarrier), findsOneWidget);

    await tester.tap(find.byKey(const Key('location_barrier_action')));
    await settle(tester);

    expect(find.byType(LocationRequiredBarrier), findsNothing);
    await tester.enterText(find.byType(TextField), 'now it sticks');
    await settle(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'now it sticks',
      reason: 'the form becomes usable once the device can locate the record',
    );
  });

  testWidgets('the recheck button picks up a grant made outside the app', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        capture: captureWith([
          LocationReadiness.permissionBlocked,
          LocationReadiness.ready,
        ]),
      ),
    );
    await settle(tester);
    expect(find.byType(LocationRequiredBarrier), findsOneWidget);

    await tester.tap(find.byKey(const Key('location_barrier_recheck')));
    await settle(tester);

    expect(find.byType(LocationRequiredBarrier), findsNothing);
  });

  testWidgets('a doctype without the capture fields is never gated', (
    tester,
  ) async {
    // A readiness that would block, on a doctype with nowhere to store a
    // location: the gate must not fire, or every form on a server without
    // mobile_control would demand permission it has no use for.
    await tester.pumpWidget(
      host(
        meta: _bare(),
        capture: captureWith([LocationReadiness.permissionBlocked]),
      ),
    );
    await settle(tester);

    expect(find.byType(LocationRequiredBarrier), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('editing an existing record is never gated', (tester) async {
    await tester.pumpWidget(
      host(
        document: Document(
          localId: 'u1',
          doctype: 'Survey',
          data: const {'mobile_uuid': 'u1', 'village': 'Rampur'},
          modified: 0,
        ),
        capture: captureWith([LocationReadiness.permissionBlocked]),
      ),
    );
    await settle(tester);

    expect(
      find.byType(LocationRequiredBarrier),
      findsNothing,
      reason: 'an existing record was already stamped when it was created',
    );
  });

  testWidgets('a blocked new record saves nothing while the barrier stands', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(capture: captureWith([LocationReadiness.permissionDenied])),
    );
    await settle(tester);

    // Save is present in the tree but unreachable; tapping it must write
    // nothing, which is the property that actually matters.
    await tester.tap(find.byKey(const Key('form_save_button')));
    await settle(tester);

    final rows = await tester.runAsync(
      () => appDb.rawDatabase.query('docs__survey'),
    );
    expect(rows, isEmpty);
  });

  // Regression tests for a defect found on a real Android 8 device: after
  // "Don't ask again" the OS stops prompting, but `checkPermission()` still
  // answers plain `denied` — only the REQUEST reports `deniedForever`. Deriving
  // the barrier's state from a check left it looping on an "Allow location"
  // button the OS had already decided to ignore.
  testWidgets('a request that reveals deniedForever escalates to settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        capture: captureWith(
          // Every CHECK says merely denied, as Android 8 does...
          [LocationReadiness.permissionDenied],
          // ...while the REQUEST is what reveals the OS has stopped asking.
          afterRequest: LocationReadiness.permissionBlocked,
        ),
      ),
    );
    await settle(tester);
    expect(find.text('Allow location'), findsOneWidget);

    await tester.tap(find.byKey(const Key('location_barrier_action')));
    await settle(tester);

    expect(
      find.text('Open settings'),
      findsOneWidget,
      reason: 'the only action that can still resolve it',
    );
    expect(find.text('Allow location'), findsNothing);
  });

  testWidgets('a blocked permission is not demoted by a later plain check', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        capture: captureWith([
          LocationReadiness.permissionDenied,
        ], afterRequest: LocationReadiness.permissionBlocked),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const Key('location_barrier_action')));
    await settle(tester);
    expect(find.text('Open settings'), findsOneWidget);

    // "check again" re-reads, and the check still under-reports as `denied`.
    await tester.tap(find.byKey(const Key('location_barrier_recheck')));
    await settle(tester);

    expect(
      find.text('Open settings'),
      findsOneWidget,
      reason: 'must not fall back to a prompt the OS ignores',
    );
  });

  testWidgets('a grant through the OS prompt clears the block immediately', (
    tester,
  ) async {
    // The check never reports ready; only the request does. The form must still
    // unblock, which it cannot do if the request result is discarded.
    await tester.pumpWidget(
      host(
        capture: captureWith([
          LocationReadiness.permissionDenied,
        ], afterRequest: LocationReadiness.ready),
      ),
    );
    await settle(tester);
    await tester.tap(find.byKey(const Key('location_barrier_action')));
    await settle(tester);

    expect(find.byType(LocationRequiredBarrier), findsNothing);
  });
}
