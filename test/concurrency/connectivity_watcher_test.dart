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
}
