import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/api/client.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/offline_transition_service.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';

class _FakeSync extends SyncService {
  final List<Future<void> Function()> _drainSteps;
  int _step = 0;

  _FakeSync(
    super.client,
    super.repo,
    super.db,
    this._drainSteps, {
    required super.getMobileUuid,
    required super.offlineMode,
  });

  @override
  Future<SyncResult> pushSync({String? doctype}) async {
    if (_step < _drainSteps.length) {
      await _drainSteps[_step++]();
    }
    return SyncResult(0, 0, 0, null);
  }
}

Future<({AppDatabase db, OfflineTransitionService service})> _make(
  List<Future<void> Function()> drainSteps,
  Future<int> Function() counter,
) async {
  final db = await AppDatabase.inMemoryDatabase();
  final client = FrappeClient('http://localhost');
  final repo = OfflineRepository(
    db,
    offlineMode: const OfflineMode(enabled: true, isPersisted: true),
    client: client,
  );
  final fakeSync = _FakeSync(
    client,
    repo,
    db,
    drainSteps,
    getMobileUuid: () async => 'test',
    offlineMode: const OfflineMode(enabled: true, isPersisted: true),
  );
  final svc = OfflineTransitionService(
    database: db,
    drainSyncFactory: () async => fakeSync,
    residueCounter: counter,
  );
  return (db: db, service: svc);
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('clean drain → emits Draining → WipingTables → Completed', () async {
    var residue = 1;
    final t = await _make([
      () async {
        residue = 0;
      },
    ], () async => residue);

    final emitted = <Type>[];
    final sub = t.service.stream.listen((s) => emitted.add(s.runtimeType));

    await t.service.runDrainAndWipe();
    await Future.delayed(Duration.zero);

    expect(
      emitted,
      containsAllInOrder([
        TransitionDraining,
        TransitionWipingTables,
        TransitionCompleted,
      ]),
    );
    await sub.cancel();
    await t.service.dispose();
    await t.db.close();
  });

  test('drain fails → DrainFailed; retry → success → Completed', () async {
    var residue = 2;
    var attempts = 0;
    final t = await _make([
      () async {
        attempts++;
        // residue stays 2 — drain "fails" silently
      },
      () async {
        attempts++;
        residue = 0;
      },
    ], () async => residue);

    final emitted = <Type>[];
    final sub = t.service.stream.listen((s) => emitted.add(s.runtimeType));

    final completer = t.service.runDrainAndWipe();
    await Future.delayed(const Duration(milliseconds: 30));
    expect(emitted, contains(TransitionDrainFailed));

    t.service.retry();
    await completer;
    await Future.delayed(Duration.zero);
    expect(t.service.current, isA<TransitionCompleted>());
    expect(attempts, 2);
    await sub.cancel();
    await t.service.dispose();
    await t.db.close();
  });

  test('progress probe updates drainedRecords as residue falls', () async {
    // Drain takes long enough for the progress timer to fire at least
    // once mid-flight. We tick the residue down in chunks during the
    // drain step and verify the emitted TransitionDraining states
    // reflect the falling count rather than staying pinned at 0.
    var residue = 10;
    final t = await _make([
      () async {
        residue = 7;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        residue = 4;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        residue = 0;
      },
    ], () async => residue);

    final draining = <int>[];
    final sub = t.service.stream.listen((s) {
      if (s is TransitionDraining) draining.add(s.drainedRecords);
    });

    await t.service.runDrainAndWipe(
      progressInterval: const Duration(milliseconds: 5),
    );

    // First emit is always 0 (start-of-drain). Subsequent emits must
    // include at least one strictly-positive drained count, proving
    // the probe ran and reported progress.
    expect(draining.isNotEmpty, isTrue);
    expect(draining.first, 0);
    expect(
      draining.any((d) => d > 0),
      isTrue,
      reason: 'progress probe should emit at least one non-zero drained count',
    );

    await sub.cancel();
    await t.service.dispose();
    await t.db.close();
  });

  test('drain fails → forceExit → Completed', () async {
    var residue = 3;
    final t = await _make([
      () async {
        // drain fails to clear residue
      },
    ], () async => residue);

    final emitted = <Type>[];
    final sub = t.service.stream.listen((s) => emitted.add(s.runtimeType));

    final completer = t.service.runDrainAndWipe();
    await Future.delayed(const Duration(milliseconds: 30));
    expect(emitted, contains(TransitionDrainFailed));

    await t.service.forceExit();
    await completer;
    await Future.delayed(Duration.zero);
    expect(t.service.current, isA<TransitionCompleted>());
    await sub.cancel();
    await t.service.dispose();
    await t.db.close();
  });
}
