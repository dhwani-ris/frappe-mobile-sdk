import 'package:flutter/material.dart';

import '../services/offline_transition_service.dart';
import 'widgets/screen_helpers.dart';

/// Full-screen UI for the offline → online transition flow.
///
/// Mount above your app's normal content (typically inside an AppGuard
/// chain or as a top-level overlay) by listening to
/// `sdk.offlineTransition.stream` and showing this widget when the
/// state is `Draining`, `WipingTables`, or `DrainFailed`.
///
/// Wraps content in `PopScope(canPop: false)` so the OS back button is
/// intercepted while the transition is active. Recents-swipe cannot be
/// blocked at the Flutter layer; that's a known UX limitation tracked
/// in the design doc.
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
        const Text('Saving your pending records before going online'),
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
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
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
    final confirm = await showConfirmDialog(
      context,
      title: 'Force exit?',
      content:
          'Discarding ${state.remainingDirty} pending record(s). '
          'This cannot be undone.',
      confirmLabel: 'Discard',
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
            FilledButton(onPressed: service.retry, child: const Text('Retry')),
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
