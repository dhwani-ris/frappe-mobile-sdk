# Offline Mode Toggle — P3: Transition handler + UI + final boot logic

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace P2's conservative residue guard with the real drain-or-block transition flow. When the persisted flag is `false` and residual offline data exists, the SDK drains the outbox + pending attachments, wipes `docs__*` and queue tables on success, or surfaces a `DrainFailed` state (with retry/force-exit) on failure. Adds the `OfflineTransitionService`, `OfflineTransitionScreen`, and integrates them into `AppGuard`.

**Architecture:** A new `OfflineTransitionService` owns a broadcast `Stream<OfflineTransitionState>` and exposes `retry()` and `forceExit()`. The SDK invokes it from `initialize()` after `restoreSession()` succeeds, before `_initialMetaAndDataSync`. Drain runs against a transient `SyncService` constructed with `OfflineMode(enabled: true, isPersisted: true)`. Wipe drops `docs__*` tables and clears `outbox`/`pending_attachments`/`link_options`. UI is mounted by `AppGuard` via a `StreamBuilder`.

**Tech Stack:** Dart (sqflite, http, flutter_test, flutter widget_test).

**Spec reference:** `docs/superpowers/specs/2026-05-01-offline-mode-toggle-design.md` §7, §10.1, §10.4(b).

**Prerequisite:** P1 + P2 merged.

**User-driven commits:** none scripted.

---

## File structure

| Path | Action | Responsibility |
|---|---|---|
| `frappe-mobile-sdk/lib/src/services/offline_transition_service.dart` | create | State stream + `retry()` + `forceExit()` + `runDrainAndWipe()` |
| `frappe-mobile-sdk/lib/src/database/app_database.dart` | modify | Add `wipeOfflineDocumentTables()` helper |
| `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart` | modify | Replace P2 residue guard; add `_runOfflineToOnlineTransition`; expose `offlineTransition` getter; `dispose()` cleans up the new service |
| `frappe-mobile-sdk/lib/src/ui/offline_transition_screen.dart` | create | Drain-progress / drain-failed / wiping UI; PopScope guard |
| `frappe-mobile-sdk/lib/src/ui/app_guard.dart` | modify | Mount `OfflineTransitionScreen` on non-Idle states |
| `frappe-mobile-sdk/test/services/offline_transition_service_test.dart` | create | State-machine unit tests |
| `frappe-mobile-sdk/test/database/wipe_offline_document_tables_test.dart` | create | Helper isolation tests |
| `frappe-mobile-sdk/test/sdk/frappe_sdk_transition_integration_test.dart` | create | End-to-end: persisted=false + residue → drain → wipe → online |
| `frappe-mobile-sdk/test/ui/offline_transition_screen_test.dart` | create | Widget test: PopScope blocks back; force-exit confirms |

---

## Task 1: `wipeOfflineDocumentTables` helper

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/database/app_database.dart`
- Create: `frappe-mobile-sdk/test/database/wipe_offline_document_tables_test.dart`

- [ ] **Step 1.1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('wipeOfflineDocumentTables drops docs__* and clears queues', () async {
    final db = await AppDatabase.inMemoryDatabase();

    await db.rawDatabase.execute(
      'CREATE TABLE docs__customer (mobile_uuid TEXT, server_name TEXT)',
    );
    await db.rawDatabase.execute(
      'CREATE TABLE docs__contact (mobile_uuid TEXT)',
    );
    await db.rawDatabase.insert(
      'docs__customer', {'mobile_uuid': 'u1', 'server_name': 'CUST-1'},
    );
    await db.rawDatabase.insert('outbox', {
      'doctype': 'Customer', 'mobile_uuid': 'u1',
      'operation': 'create', 'state': 'pending', 'created_at': 1,
    });
    await db.rawDatabase.insert('pending_attachments', {
      'parent_uuid': 'u1', 'parent_doctype': 'Customer',
      'parent_fieldname': 'attachment', 'local_path': '/tmp/x',
      'state': 'pending', 'created_at': 1,
    });
    await db.rawDatabase.insert('link_options', {
      'doctype': 'Customer', 'name': 'CUST-1', 'lastUpdated': 1,
    });

    await db.wipeOfflineDocumentTables();

    final tables = await db.rawDatabase.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'docs__%'",
    );
    expect(tables, isEmpty);

    final outbox = await db.rawDatabase.rawQuery('SELECT 1 FROM outbox');
    expect(outbox, isEmpty);
    final attach = await db.rawDatabase
        .rawQuery('SELECT 1 FROM pending_attachments');
    expect(attach, isEmpty);
    final links = await db.rawDatabase.rawQuery('SELECT 1 FROM link_options');
    expect(links, isEmpty);

    // Preserved tables
    final meta = await db.rawDatabase.rawQuery('SELECT 1 FROM doctype_meta');
    final auth = await db.rawDatabase.rawQuery('SELECT 1 FROM auth_tokens');
    final perms = await db.rawDatabase.rawQuery('SELECT 1 FROM doctype_permission');
    final sdkMeta = await db.rawDatabase.rawQuery('SELECT 1 FROM sdk_meta');
    // doctype_meta and auth_tokens may have rows or not — what matters is
    // the tables themselves still exist (rawQuery would throw otherwise).
    expect(meta, isNotNull);
    expect(auth, isNotNull);
    expect(perms, isNotNull);
    expect(sdkMeta, isNotEmpty); // sdk_meta has the singleton row

    await db.close();
  });
}
```

- [ ] **Step 1.2: Run and verify it fails**

```
flutter test test/database/wipe_offline_document_tables_test.dart
```
Expected: compile error — method not defined.

- [ ] **Step 1.3: Add the helper to `AppDatabase`**

Inside `AppDatabase`, near the existing `clearAllData`:

```dart
/// Drops every `docs__<doctype>` table and clears `outbox`,
/// `pending_attachments`, `link_options`. Preserves `doctype_meta`,
/// `auth_tokens`, `doctype_permission`, `sdk_meta`. Used by the
/// offline → online transition (Spec §7.5).
Future<void> wipeOfflineDocumentTables() async {
  await _db.transaction((txn) async {
    final tables = await txn.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name LIKE 'docs\\_\\_%' ESCAPE '\\'",
    );
    for (final r in tables) {
      final name = r['name'] as String;
      await txn.execute('DROP TABLE IF EXISTS "$name"');
    }
    await txn.delete('outbox');
    await txn.delete('pending_attachments');
    await txn.delete('link_options');
  });
}
```

- [ ] **Step 1.4: Re-run test and verify pass**

```
flutter test test/database/wipe_offline_document_tables_test.dart
```
Expected: passes.

---

## Task 2: `OfflineTransitionState` and `OfflineTransitionService` skeleton

**Files:**
- Create: `frappe-mobile-sdk/lib/src/services/offline_transition_service.dart`

- [ ] **Step 2.1: Define states and service**

```dart
import 'dart:async';
import '../database/app_database.dart';
import 'sync_service.dart';

/// Sealed hierarchy of states emitted on the transition stream.
sealed class OfflineTransitionState {
  const OfflineTransitionState();
}

class TransitionIdle extends OfflineTransitionState {
  const TransitionIdle();
}

class TransitionDraining extends OfflineTransitionState {
  final int totalRecords;
  final int drainedRecords;
  const TransitionDraining({
    required this.totalRecords,
    required this.drainedRecords,
  });
}

class TransitionDrainFailed extends OfflineTransitionState {
  final int remainingDirty;
  final int remainingFailedAttachments;
  final String? lastError;
  const TransitionDrainFailed({
    required this.remainingDirty,
    required this.remainingFailedAttachments,
    this.lastError,
  });
}

class TransitionWipingTables extends OfflineTransitionState {
  const TransitionWipingTables();
}

class TransitionCompleted extends OfflineTransitionState {
  const TransitionCompleted();
}

/// Drives the offline → online transition. Owns its own broadcast stream;
/// callers subscribe via [stream]. Public surface: [runDrainAndWipe],
/// [retry], [forceExit].
class OfflineTransitionService {
  final AppDatabase _db;
  final Future<SyncService> Function() _drainSyncFactory;
  final Future<int> Function() _residueCounter;

  final StreamController<OfflineTransitionState> _ctrl =
      StreamController.broadcast();
  Completer<void>? _userActionCompleter;

  OfflineTransitionService({
    required AppDatabase database,
    required Future<SyncService> Function() drainSyncFactory,
    required Future<int> Function() residueCounter,
  })  : _db = database,
        _drainSyncFactory = drainSyncFactory,
        _residueCounter = residueCounter {
    _ctrl.add(const TransitionIdle());
  }

  Stream<OfflineTransitionState> get stream => _ctrl.stream;

  /// Runs drain → wipe → completed. If drain fails, parks in
  /// [TransitionDrainFailed] and awaits [retry] or [forceExit].
  /// Returns once [TransitionCompleted] is reached.
  Future<void> runDrainAndWipe() async {
    while (true) {
      final initialResidue = await _residueCounter();
      _ctrl.add(TransitionDraining(
        totalRecords: initialResidue,
        drainedRecords: 0,
      ));

      String? lastError;
      try {
        final sync = await _drainSyncFactory();
        await sync.flushOutbox();
        await sync.flushPendingAttachments();
      } catch (e) {
        lastError = e.toString();
      }

      final remainingResidue = await _residueCounter();
      if (remainingResidue == 0) {
        _ctrl.add(const TransitionWipingTables());
        await _db.wipeOfflineDocumentTables();
        _ctrl.add(const TransitionCompleted());
        return;
      }

      _ctrl.add(TransitionDrainFailed(
        remainingDirty: remainingResidue,
        remainingFailedAttachments: 0, // P3.1 may split this
        lastError: lastError,
      ));

      _userActionCompleter = Completer<void>();
      await _userActionCompleter!.future;
      _userActionCompleter = null;
      // Loop: retry path re-enters the while.
    }
  }

  /// Retries the drain after [TransitionDrainFailed]. No-op if no
  /// failure is pending.
  void retry() {
    final c = _userActionCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Force-exits: drops tables unconditionally and emits
  /// [TransitionCompleted]. Used when the user accepts data loss.
  Future<void> forceExit() async {
    _ctrl.add(const TransitionWipingTables());
    await _db.wipeOfflineDocumentTables();
    _ctrl.add(const TransitionCompleted());
    final c = _userActionCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> dispose() async {
    final c = _userActionCompleter;
    if (c != null && !c.isCompleted) c.complete();
    await _ctrl.close();
  }
}
```

The `_residueCounter` returns the count of remaining residue items so the UI can display progress. The simplest implementation: `outbox` + `pending_attachments` row counts; `docs__*` table rows are no-ops to drain (they're synced-state cache, not pending writes). The actual count semantics are per implementation.

---

## Task 3: `OfflineTransitionService` unit tests

**Files:**
- Create: `frappe-mobile-sdk/test/services/offline_transition_service_test.dart`

- [ ] **Step 3.1: Write the test**

```dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/services/offline_transition_service.dart';
import 'package:frappe_mobile_sdk/src/services/sync_service.dart';
import 'package:frappe_mobile_sdk/src/services/offline_repository.dart';
import 'package:frappe_mobile_sdk/src/services/local_writer.dart';
import 'package:frappe_mobile_sdk/src/models/offline_mode.dart';

import '../helpers/fake_frappe_client.dart';

class _FakeSync extends SyncService {
  final List<Future<void> Function()> _drainSteps;
  int _step = 0;
  _FakeSync(super.client, super.repo, super.db, this._drainSteps,
      {required super.getMobileUuid, required super.offlineMode});

  @override
  Future<void> flushOutbox() async {
    if (_step < _drainSteps.length) await _drainSteps[_step++]();
  }

  @override
  Future<void> flushPendingAttachments() async {}
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<({AppDatabase db, _FakeSync sync, OfflineTransitionService service})>
      _makeService(List<Future<void> Function()> drainSteps,
          Future<int> Function() counter) async {
    final db = await AppDatabase.inMemoryDatabase();
    final client = FakeFrappeClient();
    final repo = OfflineRepository(
      db,
      localWriter: LocalWriter(db.rawDatabase, (_) async => throw 'meta'),
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
      client: client,
    );
    final sync = _FakeSync(
      client, repo, db, drainSteps,
      getMobileUuid: () async => 'test',
      offlineMode: const OfflineMode(enabled: true, isPersisted: true),
    );
    final svc = OfflineTransitionService(
      database: db,
      drainSyncFactory: () async => sync,
      residueCounter: counter,
    );
    return (db: db, sync: sync, service: svc);
  }

  test('clean drain → emits Draining → WipingTables → Completed', () async {
    int residue = 1;
    final t = await _makeService([() async { residue = 0; }],
        () async => residue);

    final emitted = <Type>[];
    final sub = t.service.stream.listen((s) => emitted.add(s.runtimeType));

    await t.service.runDrainAndWipe();
    await Future.delayed(Duration.zero);

    expect(emitted, containsAllInOrder([
      TransitionIdle, TransitionDraining,
      TransitionWipingTables, TransitionCompleted,
    ]));
    await sub.cancel();
    await t.service.dispose();
    await t.db.close();
  });

  test('drain fails → DrainFailed; retry → success → Completed', () async {
    int residue = 2;
    int drainAttempt = 0;
    final t = await _makeService([
      () async { drainAttempt++; /* fail: leave residue */ },
      () async { drainAttempt++; residue = 0; },
    ], () async => residue);

    final emitted = <Type>[];
    final sub = t.service.stream.listen((s) => emitted.add(s.runtimeType));

    final completer = t.service.runDrainAndWipe();
    // Wait until DrainFailed is emitted.
    await Future.delayed(const Duration(milliseconds: 20));
    expect(emitted, contains(TransitionDrainFailed));

    t.service.retry();
    await completer;
    expect(emitted.last, TransitionCompleted);
    expect(drainAttempt, 2);
    await sub.cancel();
    await t.service.dispose();
    await t.db.close();
  });

  test('drain fails → forceExit → Completed', () async {
    int residue = 3;
    final t = await _makeService([() async { /* drain fails */ }],
        () async => residue);

    final emitted = <Type>[];
    final sub = t.service.stream.listen((s) => emitted.add(s.runtimeType));

    final completer = t.service.runDrainAndWipe();
    await Future.delayed(const Duration(milliseconds: 20));
    expect(emitted, contains(TransitionDrainFailed));

    await t.service.forceExit();
    await completer;
    expect(emitted, contains(TransitionWipingTables));
    expect(emitted.last, TransitionCompleted);
    await sub.cancel();
    await t.service.dispose();
    await t.db.close();
  });
}
```

- [ ] **Step 3.2: Run and verify pass**

```
flutter test test/services/offline_transition_service_test.dart
```
Expected: all three tests pass.

---

## Task 4: `OfflineTransitionScreen` widget

**Files:**
- Create: `frappe-mobile-sdk/lib/src/ui/offline_transition_screen.dart`
- Create: `frappe-mobile-sdk/test/ui/offline_transition_screen_test.dart`

- [ ] **Step 4.1: Implement the screen**

```dart
import 'package:flutter/material.dart';
import '../services/offline_transition_service.dart';

class OfflineTransitionScreen extends StatelessWidget {
  final OfflineTransitionState state;
  final OfflineTransitionService service;

  const OfflineTransitionScreen({
    super.key,
    required this.state,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: switch (state) {
                TransitionDraining s => _Draining(state: s),
                TransitionWipingTables _ => const _Wiping(),
                TransitionDrainFailed s => _Failed(state: s, service: service),
                _ => const SizedBox.shrink(),
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Draining extends StatelessWidget {
  final TransitionDraining state;
  const _Draining({required this.state});
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text('Saving your pending records before going online'),
        const SizedBox(height: 8),
        Text('${state.drainedRecords} of ${state.totalRecords}'),
      ],
    );
  }
}

class _Wiping extends StatelessWidget {
  const _Wiping();
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: const [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Cleaning up local data'),
      ],
    );
  }
}

class _Failed extends StatelessWidget {
  final TransitionDrainFailed state;
  final OfflineTransitionService service;
  const _Failed({required this.state, required this.service});

  Future<void> _confirmForceExit(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Force exit?'),
        content: Text(
          'Discarding ${state.remainingDirty} pending record(s). '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirm == true) await service.forceExit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.warning_amber_rounded, size: 48),
        const SizedBox(height: 16),
        Text(
          'Could not save ${state.remainingDirty} pending record(s)',
          textAlign: TextAlign.center,
        ),
        if (state.lastError != null) ...[
          const SizedBox(height: 8),
          Text(state.lastError!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: service.retry,
              child: const Text('Retry'),
            ),
            OutlinedButton(
              onPressed: () => _confirmForceExit(context),
              child: const Text('Force exit'),
            ),
          ],
        ),
      ],
    );
  }
}
```

- [ ] **Step 4.2: Write a widget test for the PopScope guard**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/services/offline_transition_service.dart';
import 'package:frappe_mobile_sdk/src/ui/offline_transition_screen.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('PopScope blocks back navigation while transition runs',
      (tester) async {
    final db = await AppDatabase.inMemoryDatabase();
    final svc = OfflineTransitionService(
      database: db,
      drainSyncFactory: () async => throw 'unused in this test',
      residueCounter: () async => 0,
    );
    bool popped = false;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              popped = await Navigator.push<bool>(
                ctx,
                MaterialPageRoute(builder: (_) =>
                  OfflineTransitionScreen(
                    state: const TransitionDraining(
                      totalRecords: 2, drainedRecords: 1),
                    service: svc,
                  ),
                ),
              ) ?? false;
            },
            child: const Text('Push'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Push'));
    await tester.pumpAndSettle();

    // Try to pop
    final navigatorState = tester.state<NavigatorState>(find.byType(Navigator));
    await navigatorState.maybePop();
    await tester.pumpAndSettle();

    // Still on the transition screen (PopScope blocked the pop)
    expect(find.byType(OfflineTransitionScreen), findsOneWidget);
    expect(popped, isFalse);

    await svc.dispose();
    await db.close();
  });

  testWidgets('Force exit path emits Completed', (tester) async {
    final db = await AppDatabase.inMemoryDatabase();
    final svc = OfflineTransitionService(
      database: db,
      drainSyncFactory: () async => throw 'unused',
      residueCounter: () async => 0,
    );

    await tester.pumpWidget(MaterialApp(
      home: OfflineTransitionScreen(
        state: const TransitionDrainFailed(
          remainingDirty: 3,
          remainingFailedAttachments: 0,
        ),
        service: svc,
      ),
    ));

    await tester.tap(find.text('Force exit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    final stream = svc.stream;
    await expectLater(stream, emitsThrough(isA<TransitionCompleted>()));

    await svc.dispose();
    await db.close();
  });
}
```

- [ ] **Step 4.3: Run and verify pass**

```
flutter test test/ui/offline_transition_screen_test.dart
```
Expected: passes.

---

## Task 5: Integrate `OfflineTransitionScreen` into `AppGuard`

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/ui/app_guard.dart`

- [ ] **Step 5.1: Read current `AppGuard`**

Use the Read tool to confirm its current build pattern (it likely already has stream-driven gating for migration).

- [ ] **Step 5.2: Add the transition gate**

Wrap the existing child tree with a `StreamBuilder` listening to `sdk.offlineTransition.stream`:

```dart
return StreamBuilder<OfflineTransitionState>(
  stream: widget.sdk.offlineTransition.stream,
  initialData: const TransitionIdle(),
  builder: (ctx, snap) {
    final s = snap.data ?? const TransitionIdle();
    if (s is TransitionDraining ||
        s is TransitionDrainFailed ||
        s is TransitionWipingTables) {
      return OfflineTransitionScreen(
        state: s,
        service: widget.sdk.offlineTransition,
      );
    }
    return _existingChildBuilder(ctx);
  },
);
```

`_existingChildBuilder` is whatever the current AppGuard returned before. Preserve every other behavior (migration gate, auth gate, etc.). The new gate runs *outside* the existing tree so it shadows everything.

`widget.sdk.offlineTransition` is added in Task 6.

---

## Task 6: Wire `OfflineTransitionService` into `FrappeSDK`; remove P2 guard

**Files:**
- Modify: `frappe-mobile-sdk/lib/src/sdk/frappe_sdk.dart`

- [ ] **Step 6.1: Add field, getter, dispose**

```dart
OfflineTransitionService? _offlineTransitionService;

OfflineTransitionService get offlineTransition {
  if (!_initialized) {
    throw Exception('SDK not initialized.');
  }
  return _offlineTransitionService!;
}
```

In `dispose()`:
```dart
await _offlineTransitionService?.dispose();
_offlineTransitionService = null;
```

- [ ] **Step 6.2: Construct the service in `initialize`**

After service wiring in `initialize()`, before `_initialized = true`:

```dart
_offlineTransitionService = OfflineTransitionService(
  database: _database!,
  drainSyncFactory: () async => SyncService(
    _client!,
    _repository!,
    _database!,
    getMobileUuid: () => _authService!.getOrCreateMobileUuid(),
    offlineMode: const OfflineMode(enabled: true, isPersisted: true),
  ),
  residueCounter: _residueCount,
);
```

Add `_residueCount`:

```dart
Future<int> _residueCount() async {
  final raw = _database!.rawDatabase;
  final outbox = await raw.rawQuery('SELECT COUNT(*) AS c FROM outbox');
  final attach = await raw.rawQuery(
      'SELECT COUNT(*) AS c FROM pending_attachments');
  return ((outbox.first['c'] as int?) ?? 0) +
         ((attach.first['c'] as int?) ?? 0);
}
```

- [ ] **Step 6.3: Replace P2's residue guard with the real transition trigger**

Edit `_resolveBootMode`. Remove the P2 guard's "stay offline if residue exists" branch — the trigger now runs the transition explicitly. The boot mode resolves verbatim from persisted, with the unpersisted+residue case still booting offline (legacy install bootstrapping).

```dart
Future<OfflineMode> _resolveBootMode(OfflineMode persisted) async {
  if (persisted.isPersisted) return persisted;
  final hasResidue = await _hasResidualOfflineState();
  return OfflineMode(enabled: hasResidue, isPersisted: false);
}
```

In `initialize()`, inside `if (autoRestoreAndSync)` after `_authService!.restoreSession()`:

```dart
if (restored) {
  final persisted = await SdkMetaDao(_database!.rawDatabase).readOfflineMode();
  if (persisted.isPersisted &&
      !persisted.enabled &&
      await _hasResidualOfflineState()) {
    await _offlineTransitionService!.runDrainAndWipe();
  }
  await _initialMetaAndDataSync();
}
```

Note: `_offlineMode` for the current session is still derived from `_resolveBootMode(persisted)` earlier in `initialize`. With the P3 transition-after-restore, the closure pull skipping and online passthroughs continue to behave correctly because `_offlineMode.enabled` was set from the persisted value at construction time.

Edge: if the transition runs and wipes residue, `_offlineMode.enabled` was already `false` for this session (matches the persisted online value), so the SDK is correctly online once the transition completes.

- [ ] **Step 6.4: Update P2's residue-guard test**

Find `test/sdk/frappe_sdk_residue_guard_test.dart` from P2. The guard branch is gone; the test asserting "guarded offline" no longer applies. Replace its first test with:

```dart
test('persisted=online + residue → boot stays online (transition runs separately)',
    () async {
  final db = await AppDatabase.inMemoryDatabase();
  await db.rawDatabase.execute('CREATE TABLE docs__customer (mobile_uuid TEXT)');
  final sdk = FrappeSDK.forTesting('http://localhost', db);

  final mode = await sdk.resolveBootModeForTesting(
    const OfflineMode(enabled: false, isPersisted: true),
  );
  expect(mode.enabled, isFalse,
      reason: 'P3 removes the P2 guard — the transition handler '
              'is invoked from initialize() instead');

  await sdk.dispose();
  await db.close();
});
```

The other three tests in that file remain valid.

---

## Task 7: End-to-end transition integration test

**Files:**
- Create: `frappe-mobile-sdk/test/sdk/frappe_sdk_transition_integration_test.dart`

- [ ] **Step 7.1: Write the test**

```dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/database/daos/sdk_meta_dao.dart';
import 'package:frappe_mobile_sdk/src/services/offline_transition_service.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('persisted=online + residue → service runDrainAndWipe wipes tables',
      () async {
    final db = await AppDatabase.inMemoryDatabase();
    await SdkMetaDao(db.rawDatabase).writeOfflineMode(
        enabled: false, setAtMs: 1);

    // Seed residue
    await db.rawDatabase.execute(
      'CREATE TABLE docs__customer (mobile_uuid TEXT)',
    );
    await db.rawDatabase.insert('docs__customer', {'mobile_uuid': 'u1'});

    final sdk = FrappeSDK.forTesting('http://localhost', db);

    // Drive the transition directly (forTesting skips initialize()'s
    // restoreSession pathway).
    await sdk.offlineTransition.runDrainAndWipe();

    final remaining = await db.rawDatabase.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'docs__%'",
    );
    expect(remaining, isEmpty);

    await sdk.dispose();
    await db.close();
  });
}
```

- [ ] **Step 7.2: Run and verify pass**

```
flutter test test/sdk/frappe_sdk_transition_integration_test.dart
```
Expected: passes.

---

## Task 8: Final analyzer + full suite + smoke

- [ ] **Step 8.1: Analyzer**

```
cd /home/omprakash/Desktop/snf/frappe-mobile-sdk && flutter analyze
```
Expected: zero new warnings.

- [ ] **Step 8.2: Full test suite**

```
flutter test
```
Expected: all tests pass.

- [ ] **Step 8.3: Snf app analyzer (consumer compatibility check)**

```
cd /home/omprakash/Desktop/snf/snf && flutter analyze
```
Expected: no new errors. The SNF app should compile against the upgraded SDK without requiring any code changes (the new `OfflineMode` plumbing is internal; `MobileHomeScreen` and `AppGuard` continue to take an SDK instance and behave identically when `offline_enabled = true`).

---

## Self-review

**Spec coverage check (P3):**

| Spec section | Task |
|---|---|
| §7.1 — Trigger condition (`isPersisted && !enabled && residue`) | 6 |
| §7.2 — Sealed state hierarchy + service stream | 2, 3 |
| §7.3 — `runDrainAndWipe` flow | 2, 3, 7 |
| §7.4 — `OfflineTransitionScreen` + `AppGuard` mounting | 4, 5 |
| §7.5 — `wipeOfflineDocumentTables` helper | 1 |
| §7.6 — Re-entry safety (mid-drain kill resumes next launch) | 6 (initialize re-checks trigger every boot) |
| §10.1 — Transient SyncService for drain — option (a) chosen | 6 (drainSyncFactory builds one-shot) |
| §10.4(b) — Block initialize during drain success path | 6 |

**Out of scope, flagged in spec §10.2:** logout-with-pending-records reuse of this drain pattern. Track as a follow-up plan.

**Known limitation made visible:** if `initialize()` blocks on `runDrainAndWipe` and drain fails, the user sees a frozen OS splash because `runApp` hasn't mounted yet. Recovery is "force-kill and reopen" — the trigger fires again, the transition resumes. Spec §10.4 Option (a) (defer transition out of `initialize()`) is the long-term fix and is left as a follow-up plan.
