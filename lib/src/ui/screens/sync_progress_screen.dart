import 'package:flutter/material.dart';

import '../../sync/sync_state.dart';
import '../../sync/sync_state_notifier.dart';

/// Blocking screen shown during the initial bootstrap pull. Spec §7.3.
///
/// Subscribes to the SDK's [SyncStateNotifier] and renders one row per
/// doctype currently being pulled, plus `Pause` / `Cancel` buttons.
/// Pause persists cursors via the engine; Cancel triggers
/// [SyncController.cancelInitialSync] and (typically) navigates away.
///
/// Replaces the P1 [MigrationBlockedScreen] stub once the consumer
/// wires SDK init through this surface — see Task 12.
class SyncProgressScreen extends StatelessWidget {
  final SyncStateNotifier notifier;
  final Future<void> Function() onPause;
  final Future<void> Function() onCancel;

  const SyncProgressScreen({
    super.key,
    required this.notifier,
    required this.onPause,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bootstrapping your data')),
      body: StreamBuilder<SyncState>(
        stream: notifier.stream,
        initialData: notifier.value,
        builder: (ctx, snap) {
          final s = snap.data ?? SyncState.initial;
          final entries = s.perDoctype.entries.toList();
          return Column(
            children: [
              LinearProgressIndicator(value: _progressFor(s)),
              Expanded(
                child: ListView(
                  children: entries.map((e) {
                    final d = e.value;
                    final label = d.deferred
                        ? 'deferred'
                        : (d.completedAt != null
                            ? 'done: ${d.pulledCount}'
                            : '${d.pulledCount} so far');
                    return ListTile(
                      title: Text(e.key),
                      subtitle: Text(label),
                    );
                  }).toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton(
                      onPressed: onPause,
                      child: const Text('Pause'),
                    ),
                    TextButton(
                      onPressed: onCancel,
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.red),
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  double? _progressFor(SyncState s) {
    final totalDoc = s.perDoctype.length;
    if (totalDoc == 0) return null;
    final done =
        s.perDoctype.values.where((d) => d.completedAt != null).length;
    return done / totalDoc;
  }
}
