import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A doctype as `mobile_control` provisions it: the two capture fields hidden
/// and read-only, plus one visible field the user can actually fill in.
DocTypeMeta _meta() => DocTypeMeta(
  name: 'Survey',
  fields: [
    DocField(
      fieldname: mobileCreatedAtField,
      fieldtype: 'Datetime',
      hidden: true,
      readOnly: true,
    ),
    DocField(
      fieldname: mobileLatitudeLongitudeField,
      fieldtype: 'Geolocation',
      hidden: true,
      readOnly: true,
    ),
    DocField(fieldname: 'village', fieldtype: 'Data', label: 'Village'),
  ],
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

  // The AppBar Save action only renders once the form is dirty, so driving it
  // by tapping is coupled to dirty-detection rather than to the save path under
  // test. `registerSubmit` hands back the same trigger the button calls.
  void Function()? submit;

  Widget host({Document? document, required MobileCreationCapture capture}) =>
      MaterialApp(
        home: Scaffold(
          body: FormScreen(
            meta: _meta(),
            document: document,
            repository: repo,
            mode: FormBuilderMode.reactive,
            creationCapture: capture,
            registerSubmit: (trigger) => submit = trigger,
          ),
        ),
      );

  // sqflite is real I/O, which never completes inside testWidgets' fake-async
  // zone — hence `runAsync` around every step that reaches the database, and
  // bounded `pump`s instead of `pumpAndSettle`.
  Future<Map<String, Object?>> savedRow(WidgetTester tester) async {
    final rows = await tester.runAsync(
      () => appDb.rawDatabase.query('docs__survey'),
    );
    expect(rows, hasLength(1));
    return rows!.first;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> save(WidgetTester tester) async {
    expect(submit, isNotNull, reason: 'form never registered its submit');
    await tester.runAsync(() async {
      submit!();
      await tester.pump();
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await settle(tester);
  }

  testWidgets('a new record is stamped with form-open time and location', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        capture: MobileCreationCapture(
          // Ready, so the location gate never raises its barrier here; the
          // barrier itself is covered in form_screen_location_gate_test.dart.
          checkReadiness: () async => LocationReadiness.ready,
          now: () => DateTime(2026, 8, 18, 9, 5, 3),
          readLocation: () async => 'GEO',
        ),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, 'Rampur');
    await save(tester);

    final row = await savedRow(tester);
    expect(row[mobileCreatedAtField], '2026-08-18 09:05:03');
    expect(row[mobileLatitudeLongitudeField], 'GEO');
  });

  testWidgets('the timestamp is form-open time, not save time', (tester) async {
    // The clock is only ever read once, at begin(). If the implementation
    // moved the read to save time, this would return the later value.
    var call = 0;
    await tester.pumpWidget(
      host(
        capture: MobileCreationCapture(
          // Ready, so the location gate never raises its barrier here; the
          // barrier itself is covered in form_screen_location_gate_test.dart.
          checkReadiness: () async => LocationReadiness.ready,
          now: () => ++call == 1
              ? DateTime(2026, 8, 18, 9, 0, 0)
              : DateTime(2026, 8, 18, 23, 59, 59),
          readLocation: () async => null,
        ),
      ),
    );
    await settle(tester);
    await save(tester);

    expect(
      (await savedRow(tester))[mobileCreatedAtField],
      '2026-08-18 09:00:00',
    );
  });

  testWidgets('a location that never arrives does not block the save', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        capture: MobileCreationCapture(
          // Ready, so the location gate never raises its barrier here; the
          // barrier itself is covered in form_screen_location_gate_test.dart.
          checkReadiness: () async => LocationReadiness.ready,
          now: () => DateTime(2026, 8, 18, 9, 5, 3),
          // A never-completing read, with no pending Timer of its own to leak.
          readLocation: () => Completer<String?>().future,
          // Real seconds would be burned waiting; the give-up path is the same.
          saveWait: const Duration(milliseconds: 50),
        ),
      ),
    );
    await settle(tester);

    await save(tester);

    final row = await savedRow(tester);
    expect(
      row[mobileCreatedAtField],
      '2026-08-18 09:05:03',
      reason: 'the timestamp never depends on GPS',
    );
    expect(row[mobileLatitudeLongitudeField], isNull);
  });

  testWidgets('editing an existing record does not re-stamp it', (
    tester,
  ) async {
    await tester.runAsync(
      () => repo.saveDocument(
        doctype: 'Survey',
        data: {
          'mobile_uuid': 'u1',
          'village': 'Rampur',
          mobileCreatedAtField: '2026-01-01 00:00:00',
          mobileLatitudeLongitudeField: 'ORIGINAL',
        },
      ),
    );

    await tester.pumpWidget(
      host(
        document: Document(
          localId: 'u1',
          doctype: 'Survey',
          data: {
            'mobile_uuid': 'u1',
            'village': 'Rampur',
            mobileCreatedAtField: '2026-01-01 00:00:00',
            mobileLatitudeLongitudeField: 'ORIGINAL',
          },
          modified: 0,
        ),
        capture: MobileCreationCapture(
          // Ready, so the location gate never raises its barrier here; the
          // barrier itself is covered in form_screen_location_gate_test.dart.
          checkReadiness: () async => LocationReadiness.ready,
          now: () => DateTime(2026, 8, 18, 9, 5, 3),
          readLocation: () async => 'FRESH',
        ),
      ),
    );
    await settle(tester);

    await tester.enterText(find.byType(TextField).first, 'Sitapur');
    await save(tester);

    final row = await savedRow(tester);
    expect(row['village'], 'Sitapur', reason: 'the edit itself must land');
    expect(row[mobileCreatedAtField], '2026-01-01 00:00:00');
    expect(row[mobileLatitudeLongitudeField], 'ORIGINAL');
  });

  // A host that reuses one FormScreen element can swap `document` either way.
  // Both directions are wrong if the capture is not realigned — see the
  // didUpdateWidget comment in form_screen.dart.
  testWidgets('swapping new -> existing must not stamp the existing record', (
    tester,
  ) async {
    final capture = MobileCreationCapture(
      // Ready, so the location gate never raises its barrier here; the
      // barrier itself is covered in form_screen_location_gate_test.dart.
      checkReadiness: () async => LocationReadiness.ready,
      now: () => DateTime(2026, 8, 18, 9, 5, 3),
      readLocation: () async => 'FRESH',
    );

    // Opens as a NEW record, so a capture starts.
    await tester.pumpWidget(host(capture: capture));
    await settle(tester);

    // A pre-existing Desk-created row: no stamps at all.
    await tester.runAsync(
      () => repo.saveDocument(
        doctype: 'Survey',
        data: {'mobile_uuid': 'u1', 'village': 'Rampur'},
      ),
    );

    // Same element, now showing that existing record.
    await tester.pumpWidget(
      host(
        capture: capture,
        document: Document(
          localId: 'u1',
          doctype: 'Survey',
          data: const {'mobile_uuid': 'u1', 'village': 'Rampur'},
          modified: 0,
        ),
      ),
    );
    await settle(tester);
    await save(tester);

    final row = await savedRow(tester);
    expect(
      row[mobileCreatedAtField],
      isNull,
      reason: 'stamping here would date an old record with today',
    );
    expect(row[mobileLatitudeLongitudeField], isNull);
  });

  testWidgets('swapping existing -> new does stamp the new record', (
    tester,
  ) async {
    final capture = MobileCreationCapture(
      // Ready, so the location gate never raises its barrier here; the
      // barrier itself is covered in form_screen_location_gate_test.dart.
      checkReadiness: () async => LocationReadiness.ready,
      now: () => DateTime(2026, 8, 18, 9, 5, 3),
      readLocation: () async => 'GEO',
    );

    await tester.pumpWidget(
      host(
        capture: capture,
        document: Document(
          localId: 'u1',
          doctype: 'Survey',
          data: const {'mobile_uuid': 'u1', 'village': 'Rampur'},
          modified: 0,
        ),
      ),
    );
    await settle(tester);

    // "Save and add another": same element, back to a blank new record.
    await tester.pumpWidget(host(capture: capture));
    await settle(tester);
    await save(tester);

    final rows = await tester.runAsync(
      () => appDb.rawDatabase.query('docs__survey'),
    );
    expect(rows, hasLength(1));
    expect(rows!.first[mobileCreatedAtField], '2026-08-18 09:05:03');
    expect(rows.first[mobileLatitudeLongitudeField], 'GEO');
  });
}
