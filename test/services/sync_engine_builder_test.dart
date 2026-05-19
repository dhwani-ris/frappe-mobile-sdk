import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/doc_type_meta.dart';
import 'package:frappe_mobile_sdk/src/services/sync_engine_builder.dart';
import 'package:frappe_mobile_sdk/src/sync/sync_state_notifier.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

DocTypeMeta _emptyMeta(String name) =>
    DocTypeMeta(name: name, isTable: false, fields: const []);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase appDb;

  setUp(() async {
    appDb = await AppDatabase.inMemoryDatabase();
  });

  tearDown(() async => appDb.close());

  test('build() returns a non-null pack with the right object types', () async {
    final pack = await SyncEngineBuilder.build(
      database: appDb,
      client: FrappeClient('http://localhost'),
      metaResolver: (dt) async => _emptyMeta(dt),
      runPullFn: () async => const <String>{},
      applyServerDoc: (_, _) async {},
      runPullForDoctypes: (_) async {},
      concurrencyOverride: 2,
    );

    expect(pack.notifier, isNotNull);
    expect(pack.pullPool.maxConcurrent, 2);
    expect(pack.pushPool.maxConcurrent, 2);
    expect(pack.pushEngine, isNotNull);
    expect(pack.pullEngine, isNotNull);
    expect(pack.controller, isNotNull);
  });

  test(
    'pushPool and pullPool are independent ConcurrencyPool instances',
    () async {
      final pack = await SyncEngineBuilder.build(
        database: appDb,
        client: FrappeClient('http://localhost'),
        metaResolver: (dt) async => _emptyMeta(dt),
        runPullFn: () async => const <String>{},
        applyServerDoc: (_, _) async {},
        runPullForDoctypes: (_) async {},
        concurrencyOverride: 4,
      );

      expect(identical(pack.pushPool, pack.pullPool), isFalse);
    },
  );

  test('shared notifier is honored when supplied', () async {
    final shared = SyncStateNotifier();
    final pack = await SyncEngineBuilder.build(
      database: appDb,
      client: FrappeClient('http://localhost'),
      metaResolver: (dt) async => _emptyMeta(dt),
      runPullFn: () async => const <String>{},
      applyServerDoc: (_, _) async {},
      runPullForDoctypes: (_) async {},
      sharedNotifier: shared,
      concurrencyOverride: 2,
    );

    expect(identical(pack.notifier, shared), isTrue);
    await shared.close();
  });
}
