// Regression coverage for the boot-sync defer in
// FrappeSDK._doInitialize (lib/src/sdk/frappe_sdk.dart):
//
//   _initialSyncFuture = _initialMetaAndDataSync();
//   unawaited(_initialSyncFuture!);
//
// `initialize()` must return as soon as `_doInitialize` finishes, WITHOUT
// waiting for the boot-time meta + data sync to settle — otherwise a
// returning user's cold start blocks the first frame behind a sync that
// can take tens of seconds. The sync itself is tracked on
// `initialSyncFuture` for observability / tests.
//
// LIMITATION: driving `initialize(true)` end-to-end (the real
// `_doInitialize` autoRestoreAndSync path) would exercise
// `AuthService.restoreSession()` (FlutterSecureStorage), a real
// `AppDatabase.getInstance()` (path_provider), and
// `ConnectivityWatcher.production()` — none of which have test doubles in
// this SDK, and no existing test in this suite drives that path (the
// existing convention, e.g. `frappe_sdk_upgrade_pull_test.dart`, is to
// exercise the *effect* — here, `_runUpgradeClosurePull` — via
// `FrappeSDK.forTesting` + injection seams, never the literal boot path).
// This test follows that same convention: it exercises the identical
// fire-and-forget pattern (same field, same `unawaited` call) via the
// `deferInitialSyncForTesting` test seam added alongside this change,
// with an injectable sync function so the async gap is deterministic
// instead of network-timed.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/app_database.dart';
import 'package:frappe_mobile_sdk/src/sdk/frappe_sdk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  // Supplementary source guard: `deferInitialSyncForTesting` above proves
  // the *pattern* (assign-then-unawaited) behaves correctly in isolation,
  // but it does not execute `_doInitialize` itself. This check pins the
  // actual production statement so a future edit that reintroduces
  // `await _initialMetaAndDataSync()` inside `_doInitialize` — the exact
  // bug this change fixed (white-screen hang on cold start) — fails a test
  // instead of only being caught by manual/emulator verification.
  test(
    '_doInitialize defers the initial sync — source guard',
    () {
      final source = File(
        'lib/src/sdk/frappe_sdk.dart',
      ).readAsStringSync();
      final doInitializeStart = source.indexOf('Future<void> _doInitialize(');
      expect(
        doInitializeStart,
        greaterThanOrEqualTo(0),
        reason: '_doInitialize not found — has it been renamed/moved?',
      );
      // Method body ends where the next top-level method/getter begins;
      // `_runOfflineToOnlineTransitionIfNeeded` is the very next member.
      final nextMemberStart = source.indexOf(
        'Future<void> runOfflineTransitionIfPending',
        doInitializeStart,
      );
      expect(nextMemberStart, greaterThan(doInitializeStart));
      final body = source.substring(doInitializeStart, nextMemberStart);

      expect(
        body,
        contains('_initialSyncFuture = _initialMetaAndDataSync();'),
        reason:
            'the boot sync must be assigned to _initialSyncFuture, not '
            'awaited inline',
      );
      expect(
        body,
        isNot(contains('await _initialMetaAndDataSync()')),
        reason:
            'REGRESSION: _doInitialize is awaiting the initial sync again '
            '— this reintroduces the boot-time white-screen hang on cold '
            'start for returning users',
      );
    },
  );

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('initialSyncFuture is null until the defer fires', () async {
    final db = await AppDatabase.inMemoryDatabase();
    final sdk = FrappeSDK.forTesting('http://localhost', db);
    addTearDown(() => db.close());

    expect(sdk.initialSyncFuture, isNull);
  });

  test(
    'deferInitialSyncForTesting returns before the deferred sync settles',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);
      addTearDown(() => db.close());

      final gate = Completer<void>();
      var syncSettled = false;

      // This call is synchronous (void, no await) — exactly like the two
      // lines it reproduces inside _doInitialize. It must not block on
      // `gate.future`.
      sdk.deferInitialSyncForTesting(() => gate.future);
      sdk.initialSyncFuture!.whenComplete(() => syncSettled = true);

      // Control has already returned to this line — prove the deferred
      // sync genuinely hasn't run to completion yet, by yielding several
      // microtasks/event-loop turns without ever completing `gate`. If
      // `_doInitialize` had awaited the sync instead of deferring it, the
      // call above would not have returned until `gate.future` completed
      // — which never happens in this test, so the test would hang/time
      // out instead of reaching this assertion.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        syncSettled,
        isFalse,
        reason:
            'the deferred sync is still pending — deferInitialSyncForTesting '
            'must not have awaited it',
      );
      expect(sdk.initialSyncFuture, isNotNull);

      // Now let the deferred sync settle and confirm it eventually does.
      gate.complete();
      await sdk.initialSyncFuture;
      expect(syncSettled, isTrue);
    },
  );

  test(
    'a deferred sync that throws does not propagate to the caller of deferInitialSyncForTesting',
    () async {
      final db = await AppDatabase.inMemoryDatabase();
      final sdk = FrappeSDK.forTesting('http://localhost', db);
      addTearDown(() => db.close());

      // Calling this must not throw synchronously even though the
      // injected sync function fails — matches `unawaited`'s contract
      // that the caller (_doInitialize) never sees this error directly.
      sdk.deferInitialSyncForTesting(() async {
        throw Exception('boot sync failed');
      });

      expect(sdk.initialSyncFuture, isNotNull);

      // The failure is still observable via initialSyncFuture for callers
      // that choose to await/inspect it (tests, diagnostics) — it is not
      // silently swallowed, only decoupled from the caller of initialize().
      await expectLater(
        sdk.initialSyncFuture,
        throwsA(isA<Exception>()),
      );
    },
  );
}
