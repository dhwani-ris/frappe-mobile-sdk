import 'package:flutter/material.dart';

import '../sdk/frappe_sdk.dart';
import '../services/offline_transition_service.dart';
import 'offline_transition_screen.dart';

/// Wraps a child widget and shows [OfflineTransitionScreen] when the
/// SDK's [OfflineTransitionService] is in any non-idle state.
///
/// Usage:
/// ```dart
/// home: OfflineTransitionGuard(
///   sdk: _sdk!,
///   child: MyHomeScreen(...),
/// )
/// ```
///
/// Subscribes to `sdk.offlineTransition.stream` and overlays the
/// transition UI for as long as a drain / wipe / failed state is
/// active. Once the service emits [TransitionCompleted], the child
/// is shown again.
class OfflineTransitionGuard extends StatelessWidget {
  final FrappeSDK sdk;
  final Widget child;

  const OfflineTransitionGuard({
    super.key,
    required this.sdk,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final service = sdk.offlineTransition;
    return StreamBuilder<OfflineTransitionState>(
      stream: service.stream,
      initialData: service.current,
      builder: (ctx, snap) {
        final state = snap.data ?? const TransitionIdle();
        if (state is TransitionDraining ||
            state is TransitionDrainFailed ||
            state is TransitionWipingTables) {
          return OfflineTransitionScreen(state: state, service: service);
        }
        return child;
      },
    );
  }
}
