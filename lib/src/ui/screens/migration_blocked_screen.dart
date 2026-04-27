import 'package:flutter/material.dart';

/// Blocking screen shown while the v1→v2 data migration needs network
/// connectivity. User cannot enter the app until the migration completes.
///
/// The consumer app is responsible for showing this screen when
/// [FrappeSDK.runV1ToV2MigrationIfNeeded] throws
/// [MigrationNeedsNetworkException], and for invoking the [onRetry] callback
/// (typically a re-attempt of the migration call).
///
/// Visual polish lands in P6.
class MigrationBlockedScreen extends StatelessWidget {
  final VoidCallback onRetry;
  final bool isOnline;
  final String? lastError;

  const MigrationBlockedScreen({
    super.key,
    required this.onRetry,
    required this.isOnline,
    this.lastError,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_sync, size: 64),
                const SizedBox(height: 16),
                const Text(
                  'Preparing your data',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  isOnline
                      ? 'Updating local database for offline use…'
                      : 'Waiting for network to upgrade your local database.',
                  textAlign: TextAlign.center,
                ),
                if (lastError != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    lastError!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ],
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
