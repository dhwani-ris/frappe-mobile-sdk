import 'package:flutter/material.dart';

import '../../sync/sync_state.dart';
import '../../sync/sync_state_notifier.dart';

/// Top-of-screen sync status strip. Spec §7.2.
///
/// Subscribes to a [SyncStateNotifier] and renders a single label per
/// the §7.1 priority ladder:
///
///   Offline > Paused > Initial sync > Pushing > Uploading > Pulling > hidden
///
/// When the SDK is idle and online, the bar collapses to a zero-height
/// `SizedBox` so the parent layout doesn't reserve space.
class SyncStatusBar extends StatelessWidget {
  final SyncStateNotifier notifier;
  final double height;

  const SyncStatusBar({
    super.key,
    required this.notifier,
    this.height = 24,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncState>(
      stream: notifier.stream,
      initialData: notifier.value,
      builder: (ctx, snap) {
        final s = snap.data ?? SyncState.initial;
        final label = _labelFor(s);
        if (label == null) return const SizedBox.shrink();
        return Container(
          height: height,
          color: _colorFor(s),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        );
      },
    );
  }

  static String? _labelFor(SyncState s) {
    if (!s.isOnline) return 'Offline';
    if (s.isPaused) return 'Paused';
    if (s.isInitialSync) return 'Initial sync';
    if (s.isPushing) {
      final n = s.queue.pending + s.queue.inFlight;
      return n > 0 ? 'Syncing $n' : 'Syncing';
    }
    if (s.isUploading) return 'Uploading';
    if (s.isPulling) {
      final total = s.perDoctype.values
          .fold<int>(0, (acc, v) => acc + v.pulledCount);
      return total > 0 ? 'Pulling $total' : 'Pulling';
    }
    return null;
  }

  static Color _colorFor(SyncState s) {
    if (!s.isOnline) return Colors.grey;
    if (s.isPaused) return Colors.amber;
    return Colors.blueGrey;
  }
}
