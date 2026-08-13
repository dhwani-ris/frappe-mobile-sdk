import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/frappe_mobile_sdk.dart';

/// A child that owns state, so an unmount is observable.
///
/// The guard sits above the host's navigator in `MaterialApp.builder`, so
/// anything that replaces `widget.child` — even for one frame — unmounts every
/// route and every half-filled form on it. `taps` stands in for that form data.
class _StatefulChild extends StatefulWidget {
  const _StatefulChild();

  @override
  State<_StatefulChild> createState() => _StatefulChildState();
}

class _StatefulChildState extends State<_StatefulChild> {
  static int mounts = 0;
  static int disposals = 0;

  int taps = 0;

  @override
  void initState() {
    super.initState();
    mounts++;
  }

  @override
  void dispose() {
    disposals++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: TextButton(
        onPressed: () => setState(() => taps++),
        child: Text('taps: $taps'),
      ),
    );
  }
}

/// Sends a real background/foreground cycle through the lifecycle channel, the
/// same path the engine uses. `paused` first because the binding drops a
/// transition to the state it is already in.
Future<void> _backgroundThenResume() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final state in const [
    'AppLifecycleState.inactive',
    'AppLifecycleState.paused',
    'AppLifecycleState.resumed',
  ]) {
    await messenger.handlePlatformMessage(
      'flutter/lifecycle',
      const StringCodec().encodeMessage(state),
      (_) {},
    );
  }
}

/// Scripted status source for the guard's [FrappeAppGuard.statusFetcher] seam.
///
/// Needed because `testWidgets` installs a global `HttpOverrides` that answers
/// every real `dart:io` request with a synthetic 400 — a widget test can never
/// produce a genuine `SocketException`, so the fail-open path is untestable
/// through the network.
class _ScriptedStatus {
  final List<FutureOr<AppStatus> Function()> _script;
  int calls = 0;

  _ScriptedStatus(this._script);

  Future<AppStatus> fetch() async {
    final index = calls < _script.length ? calls : _script.length - 1;
    calls++;
    return await _script[index]();
  }
}

AppStatus _allowed() => const AppStatus(
  enabled: true,
  packageName: 'com.example.test',
  version: '54',
);

Widget _guard({
  required AppStatusFetcher fetcher,
  Object? recheckToken,
  Duration throttle = Duration.zero,
  Widget child = const _StatefulChild(),
}) {
  return MaterialApp(
    home: FrappeAppGuard(
      baseUrl: 'http://status.test',
      currentPackageName: 'com.example.test',
      currentVersion: '54',
      statusFetcher: fetcher,
      recheckToken: recheckToken,
      recheckThrottle: throttle,
      child: child,
    ),
  );
}

void main() {
  setUp(() {
    _StatefulChildState.mounts = 0;
    _StatefulChildState.disposals = 0;
  });

  group('ForceUpdateInfo', () {
    test('carries the title and store url handed to it', () async {
      var opened = 0;
      final info = ForceUpdateInfo(
        title: 'Update required',
        storeUrl: 'https://example.test/app',
        openStore: () async => opened++,
      );

      expect(info.title, 'Update required');
      expect(info.storeUrl, 'https://example.test/app');
      await info.openStore();
      expect(opened, 1);
    });
  });

  group('FrappeAppGuard', () {
    testWidgets('renders the child when no base url is configured', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FrappeAppGuard(baseUrl: '', child: Text('inner app')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('inner app'), findsOneWidget);
    });

    testWidgets('an unreachable server does not block the child', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FrappeAppGuard(
            baseUrl: 'http://127.0.0.1:1',
            currentPackageName: 'com.example.test',
            currentVersion: '54',
            child: Text('inner app'),
          ),
        ),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('inner app'), findsOneWidget);
    });

    testWidgets(
      'a recheckToken change re-checks without unmounting the child',
      (tester) async {
        // Deliberately does NOT use the fetcher seam: this is the shape of the
        // defect as the consuming app hits it, and it must fail against the
        // old spinner-on-recheck implementation.
        Widget build(Object token) => MaterialApp(
          home: FrappeAppGuard(
            baseUrl: 'http://127.0.0.1:1',
            currentPackageName: 'com.example.test',
            currentVersion: '54',
            recheckToken: token,
            child: const _StatefulChild(),
          ),
        );

        await tester.pumpWidget(build(1));
        await tester.pumpAndSettle(const Duration(seconds: 2));
        expect(find.text('taps: 0'), findsOneWidget);

        await tester.tap(find.byType(TextButton));
        await tester.pump();
        expect(find.text('taps: 1'), findsOneWidget);

        // The frame pumpWidget itself produces: a re-check is in flight, and
        // the child must still be on screen with its state intact.
        await tester.pumpWidget(build(2));
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('taps: 1'), findsOneWidget);

        await tester.pumpAndSettle(const Duration(seconds: 2));
        expect(find.text('taps: 1'), findsOneWidget);
        expect(_StatefulChildState.disposals, 0);
        expect(_StatefulChildState.mounts, 1);
      },
    );
  });

  group('FrappeAppGuard verdicts', () {
    testWidgets('an allowed verdict renders the child', (tester) async {
      final status = _ScriptedStatus([_allowed]);
      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();

      expect(find.text('taps: 0'), findsOneWidget);
      expect(status.calls, 1);
    });

    testWidgets('the first check shows a spinner while it is in flight', (
      tester,
    ) async {
      final gate = Completer<AppStatus>();
      await tester.pumpWidget(_guard(fetcher: () => gate.future));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('taps: 0'), findsNothing);

      gate.complete(_allowed());
      await tester.pumpAndSettle();
      expect(find.text('taps: 0'), findsOneWidget);
    });

    testWidgets('enabled=false renders the not-configured screen', (
      tester,
    ) async {
      final status = _ScriptedStatus([() => const AppStatus(enabled: false)]);
      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();

      expect(find.text('App not configured'), findsOneWidget);
      expect(find.text('taps: 0'), findsNothing);
    });

    testWidgets('maintenance_mode renders the maintenance screen', (
      tester,
    ) async {
      final status = _ScriptedStatus([
        () => const AppStatus(
          enabled: true,
          maintenanceMode: true,
          maintenanceMessage: 'Down for upgrade',
        ),
      ]);
      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();

      expect(find.text('Under maintenance'), findsOneWidget);
      expect(find.text('Down for upgrade'), findsOneWidget);
    });

    testWidgets('a version below the floor renders the force-update screen', (
      tester,
    ) async {
      final status = _ScriptedStatus([
        () => const AppStatus(
          enabled: true,
          packageName: 'com.example.test',
          version: '60',
          storeUrl: 'https://store.test/app',
        ),
      ]);
      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();

      expect(find.text('Update Required'), findsOneWidget);
      expect(find.text('taps: 0'), findsNothing);
    });

    testWidgets('a 417 from the server renders the not-configured screen', (
      tester,
    ) async {
      final status = _ScriptedStatus([
        () => throw ValidationException('not configured'),
      ]);
      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();

      expect(find.text('App not configured'), findsOneWidget);
    });

    testWidgets('a transport failure on the first check fails open', (
      tester,
    ) async {
      final status = _ScriptedStatus([
        () => throw const SocketishException('offline'),
      ]);
      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();

      expect(find.text('taps: 0'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('FrappeAppGuard resume re-check', () {
    testWidgets('a re-check that returns allowed is invisible to the user', (
      tester,
    ) async {
      final gate = Completer<AppStatus>();
      final status = _ScriptedStatus([_allowed, () => gate.future]);

      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton));
      await tester.pump();
      expect(find.text('taps: 1'), findsOneWidget);

      await _backgroundThenResume();
      await tester.pump();
      expect(status.calls, 2, reason: 'resume should trigger a re-check');

      // In flight: no spinner, no flash, no lost state.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('taps: 1'), findsOneWidget);

      gate.complete(_allowed());
      await tester.pumpAndSettle();
      expect(find.text('taps: 1'), findsOneWidget);
      expect(_StatefulChildState.disposals, 0);
      expect(_StatefulChildState.mounts, 1);
    });

    testWidgets('a re-check that fails to reach the server leaves the child', (
      tester,
    ) async {
      final status = _ScriptedStatus([
        _allowed,
        () => throw const SocketishException('offline'),
      ]);

      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextButton));
      await tester.pump();

      await _backgroundThenResume();
      await tester.pumpAndSettle();

      expect(status.calls, 2);
      expect(find.text('taps: 1'), findsOneWidget);
      expect(_StatefulChildState.disposals, 0);
    });

    testWidgets('a re-check that blocks does replace the child', (
      tester,
    ) async {
      final status = _ScriptedStatus([
        _allowed,
        () => const AppStatus(
          enabled: true,
          packageName: 'com.example.test',
          version: '60',
          storeUrl: 'https://store.test/app',
        ),
      ]);

      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();
      expect(find.text('taps: 0'), findsOneWidget);

      await _backgroundThenResume();
      await tester.pumpAndSettle();

      expect(find.text('Update Required'), findsOneWidget);
      expect(find.text('taps: 0'), findsNothing);
    });

    testWidgets('a blocked build stays blocked when the re-check goes offline', (
      tester,
    ) async {
      // The airplane-mode bypass: the old code cleared the blocked flags
      // before re-fetching, so a failed re-check handed the app back.
      final status = _ScriptedStatus([
        () => const AppStatus(enabled: false),
        () => throw const SocketishException('offline'),
      ]);

      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();
      expect(find.text('App not configured'), findsOneWidget);

      await _backgroundThenResume();
      await tester.pumpAndSettle();

      expect(status.calls, 2);
      expect(find.text('App not configured'), findsOneWidget);
      expect(find.text('taps: 0'), findsNothing);
    });

    testWidgets('a re-check clears a block once the server says allowed', (
      tester,
    ) async {
      final status = _ScriptedStatus([
        () => const AppStatus(
          enabled: true,
          maintenanceMode: true,
          maintenanceMessage: 'Down for upgrade',
        ),
        _allowed,
      ]);

      await tester.pumpWidget(_guard(fetcher: status.fetch));
      await tester.pumpAndSettle();
      expect(find.text('Under maintenance'), findsOneWidget);

      await _backgroundThenResume();
      await tester.pumpAndSettle();

      expect(find.text('taps: 0'), findsOneWidget);
      expect(find.text('Under maintenance'), findsNothing);
    });

    testWidgets('resumes inside the throttle window do not re-check', (
      tester,
    ) async {
      final status = _ScriptedStatus([_allowed]);
      await tester.pumpWidget(
        _guard(fetcher: status.fetch, throttle: const Duration(minutes: 1)),
      );
      await tester.pumpAndSettle();
      expect(status.calls, 1);

      await _backgroundThenResume();
      await tester.pumpAndSettle();

      expect(status.calls, 1, reason: 'throttled, so no second request');
    });

    testWidgets('a stale in-flight verdict cannot overwrite a newer one', (
      tester,
    ) async {
      final slow = Completer<AppStatus>();
      final status = _ScriptedStatus([
        _allowed,
        () => slow.future, // resume: slow, and will answer "blocked"
        () => const AppStatus(enabled: true, packageName: 'com.example.test'),
      ]);

      Widget build(Object token) =>
          _guard(fetcher: status.fetch, recheckToken: token);

      await tester.pumpWidget(build(1));
      await tester.pumpAndSettle();

      // Resume kicks off the slow call.
      await _backgroundThenResume();
      await tester.pump();
      expect(status.calls, 2);

      // A token change starts a newer check, which answers first and allows.
      await tester.pumpWidget(build(2));
      await tester.pumpAndSettle();
      expect(status.calls, 3);
      expect(find.text('taps: 0'), findsOneWidget);

      // The stale call now answers "blocked" — it must be discarded.
      slow.complete(const AppStatus(enabled: false));
      await tester.pumpAndSettle();

      expect(find.text('App not configured'), findsNothing);
      expect(find.text('taps: 0'), findsOneWidget);
    });
  });
}

/// Stands in for a `SocketException`: any non-HTTP error the status call can
/// throw. The guard must fail open on the first check and change nothing on a
/// re-check.
class SocketishException implements Exception {
  final String message;
  const SocketishException(this.message);
  @override
  String toString() => 'SocketishException: $message';
}
