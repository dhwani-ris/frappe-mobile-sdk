import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/concurrency/connectivity_watcher.dart';

void main() {
  test('reports online/offline via stream', () async {
    final controller = StreamController<bool>();
    final w = ConnectivityWatcher.fromStream(
      initial: false,
      stream: controller.stream,
    );
    expect(w.isOnline, isFalse);
    final seen = <bool>[];
    final sub = w.onChange.listen(seen.add);
    controller.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(w.isOnline, isTrue);
    controller.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [true, false]);
    await sub.cancel();
    await controller.close();
  });

  test(
    'dedupes duplicate states — same-as-current emits do not propagate',
    () async {
      final controller = StreamController<bool>();
      final w = ConnectivityWatcher.fromStream(
        initial: false,
        stream: controller.stream,
      );
      final seen = <bool>[];
      final sub = w.onChange.listen(seen.add);
      // Initial state is false; pushing false again must NOT emit.
      controller.add(false);
      controller.add(false);
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
      // Real edge → emits.
      controller.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [true]);
      // Same-as-current duplicates after the edge.
      controller.add(true);
      controller.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [true]);
      await sub.cancel();
      await controller.close();
    },
  );

  test('addOnRestoreCallback fires on false→true transition', () async {
    final c = StreamController<bool>();
    final w = ConnectivityWatcher.fromStream(initial: false, stream: c.stream);
    var count = 0;
    w.addOnRestoreCallback(() => count++);
    c.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(count, 0);
    c.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(count, 1);
    c.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(count, 1, reason: 'no re-fire on same state');
    c.add(false);
    await Future<void>.delayed(Duration.zero);
    c.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(count, 2);
    await c.close();
  });

  test('dispose cancels subscription and closes controller', () async {
    final controller = StreamController<bool>();
    final w = ConnectivityWatcher.fromStream(
      initial: false,
      stream: controller.stream,
    );
    final seen = <bool>[];
    final sub = w.onChange.listen(seen.add);
    controller.add(true);
    await Future<void>.delayed(Duration.zero);
    expect(seen, [true]);

    await w.dispose();

    // After dispose, source-stream events MUST NOT mutate watcher state.
    controller.add(false);
    await Future<void>.delayed(Duration.zero);
    expect(w.isOnline, isTrue, reason: 'state frozen after dispose');

    await sub.cancel();
    await controller.close();
  });

  test('dispose is idempotent — second call is a no-op', () async {
    final controller = StreamController<bool>();
    final w = ConnectivityWatcher.fromStream(
      initial: false,
      stream: controller.stream,
    );
    await w.dispose();
    await w.dispose(); // must not throw
    await controller.close();
  });
}
