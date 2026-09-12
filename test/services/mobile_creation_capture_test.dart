import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/services/mobile_creation_capture.dart';

void main() {
  test('startedAt is the moment begin() was called, not save time', () {
    final capture = MobileCreationCapture(
      now: () => DateTime(2026, 8, 18, 9, 5, 3),
      readLocation: () async => null,
    );

    expect(capture.begin().startedAt, DateTime(2026, 8, 18, 9, 5, 3));
  });

  test('returns the location once the read resolves', () async {
    final capture = MobileCreationCapture(readLocation: () async => 'geo');

    expect(await capture.begin().location(), 'geo');
  });

  test('a read still in flight at save time yields null, not a hang', () async {
    final capture = MobileCreationCapture(
      readLocation: () => Completer<String?>().future, // never completes
    );

    expect(
      await capture.begin().location(timeout: const Duration(milliseconds: 50)),
      isNull,
    );
  });

  test('a fix arriving after the timeout is still readable later', () async {
    final completer = Completer<String?>();
    final capture = MobileCreationCapture(readLocation: () => completer.future);
    final pending = capture.begin();

    expect(
      await pending.location(timeout: const Duration(milliseconds: 10)),
      isNull,
      reason: 'first read gives up',
    );

    completer.complete('late geo');
    expect(
      await pending.location(timeout: const Duration(milliseconds: 10)),
      'late geo',
      reason: 'the read was never cancelled, so a later caller sees it',
    );
  });

  test(
    'a throwing location read degrades to null instead of propagating',
    () async {
      final capture = MobileCreationCapture(
        readLocation: () async => throw StateError('no gps'),
      );

      expect(await capture.begin().location(), isNull);
    },
  );

  test('a synchronously throwing reader is also contained', () async {
    final capture = MobileCreationCapture(
      readLocation: () => throw StateError('boom'),
    );

    expect(await capture.begin().location(), isNull);
  });

  test('each begin() starts an independent capture', () async {
    var call = 0;
    final capture = MobileCreationCapture(
      readLocation: () async => 'fix${++call}',
    );

    expect(await capture.begin().location(), 'fix1');
    expect(await capture.begin().location(), 'fix2');
  });
}
