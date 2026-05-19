import 'package:flutter/material.dart';

import '../../api/utils.dart';
import '../../sync/sync_state.dart';
import '../../sync/sync_state_notifier.dart';

/// Blocking screen shown during the initial bootstrap pull. Spec §7.3.
///
/// Subscribes to the SDK's [SyncStateNotifier] and renders one row per
/// doctype currently being pulled, plus `Pause` / `Cancel` buttons.
/// Pause persists cursors via the engine; Cancel triggers
/// [SyncController.cancelInitialSync] and (typically) navigates away.
///
/// Used as the bootstrap progress surface during initial sync.
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
                    return ListTile(title: Text(e.key), subtitle: Text(label));
                  }).toList(),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    OutlinedButton(
                      onPressed: () => _runAndSurface(ctx, onPause, 'Pause'),
                      child: const Text('Pause'),
                    ),
                    TextButton(
                      onPressed: () => _runAndSurface(ctx, onCancel, 'Cancel'),
                      style: TextButton.styleFrom(foregroundColor: Colors.red),
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
    final done = s.perDoctype.values.where((d) => d.completedAt != null).length;
    return done / totalDoc;
  }
}

/// Awaits an async button action and surfaces any error via SnackBar.
/// Without this, `onPressed: someFutureFn` lets Dart silently discard
/// the returned Future, turning async exceptions into uncaught zone
/// errors that never reach the user (PR#36 round-2 M12).
Future<void> _runAndSurface(
  BuildContext context,
  Future<void> Function() action,
  String label,
) async {
  try {
    await action();
  } catch (e, st) {
    debugPrint('SyncProgressScreen: $label failed — $e\n$st');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$label failed: ${toUserFriendlyMessage(e)}'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
