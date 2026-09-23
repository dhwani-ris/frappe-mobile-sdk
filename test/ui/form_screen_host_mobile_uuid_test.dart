import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/utils/uuid_pattern.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The host's pre-generated `mobile_uuid` must be the one this screen saves.
///
/// A host that mints the id up front uses it for its own checkpoint/outbox
/// bookkeeping and to re-open the record once the create returns. When the
/// screen minted a second uuid instead, the document saved under one id and
/// the host looked for it under another — the save succeeded and the host
/// showed "not found".
///
/// Mounts the REAL screen and reads the identity it is carrying, so deleting
/// the adoption from `form_screen.dart` fails these.
DocTypeMeta _meta() => DocTypeMeta(
  name: 'Visit',
  fields: [DocField(fieldname: 'title', fieldtype: 'Data', label: 'Title')],
);

Document _existing() => Document(
  localId: 'local-visit-1',
  doctype: 'Visit',
  serverId: 'VISIT-0001',
  data: const {'title': 'a'},
  modified: 0,
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
  });

  tearDown(() async => appDb.close());

  String uuidOf(WidgetTester tester) {
    final dynamic state = tester.state(find.byType(FormScreen));
    return state.documentMobileUuidForTesting as String;
  }

  Future<void> pumpWith(
    WidgetTester tester,
    Document? document, {
    Future<String?> Function()? getMobileUuid,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FormScreen(
            meta: _meta(),
            repository: repo,
            document: document,
            getMobileUuid: getMobileUuid,
          ),
        ),
      ),
    );
    // Adoption is async — let the lookup settle before reading the identity.
    await tester.pumpAndSettle();
  }

  const hostUuid = '2cf48956-b5dc-44a8-8383-fb67ec412746';

  testWidgets('a new document adopts the host-supplied mobile_uuid', (
    tester,
  ) async {
    await pumpWith(tester, null, getMobileUuid: () async => hostUuid);
    expect(uuidOf(tester), hostUuid);
  });

  testWidgets('with no host id the screen still mints a usable uuid', (
    tester,
  ) async {
    await pumpWith(tester, null);
    final minted = uuidOf(tester);
    expect(minted, isNotEmpty);
    expect(looksLikeMobileUuid(minted), isTrue);
  });

  testWidgets('an empty or null host id falls back to a minted uuid', (
    tester,
  ) async {
    await pumpWith(tester, null, getMobileUuid: () async => '');
    expect(looksLikeMobileUuid(uuidOf(tester)), isTrue);

    await pumpWith(tester, null, getMobileUuid: () async => null);
    expect(looksLikeMobileUuid(uuidOf(tester)), isTrue);
  });

  testWidgets('an existing record stays locked to its localId', (tester) async {
    // System-owned metadata: a host id must never override an existing
    // lineage, or the edit forks a second docs__ row.
    await pumpWith(tester, _existing(), getMobileUuid: () async => hostUuid);
    expect(uuidOf(tester), 'local-visit-1');
  });

  testWidgets(
    'save-and-add-another does NOT reuse the host id for the next document',
    (tester) async {
      // The host id belongs to the document just finished. Reusing it would
      // make the next create resolve to the previous record.
      await pumpWith(tester, _existing(), getMobileUuid: () async => hostUuid);
      expect(uuidOf(tester), 'local-visit-1');

      await pumpWith(tester, null, getMobileUuid: () async => hostUuid);
      final next = uuidOf(tester);
      expect(next, isNot('local-visit-1'));
      expect(next, isNot(hostUuid));
      expect(looksLikeMobileUuid(next), isTrue);
    },
  );
}
