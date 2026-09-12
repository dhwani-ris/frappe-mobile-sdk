import 'package:flutter/material.dart';

import '../../services/location_readiness.dart';
import '../../utils/translate.dart';

/// Blocks a new record from being filled in until the device can locate it.
///
/// Rendered OVER the form rather than as a dialog, and deliberately not
/// dismissible: the record must not be started while the device is incapable of
/// recording where it was started. `Back` is left alone on purpose — the user
/// may abandon the record, they just may not enter one without a location. A
/// barrier that also swallowed `Back` would trap a user whose device has
/// permanently refused the permission.
///
/// Each state gets the only action that can actually resolve it: an askable
/// denial takes the OS dialog, a blocked one takes app Settings, a disabled
/// service takes location Settings.
class LocationRequiredBarrier extends StatelessWidget {
  const LocationRequiredBarrier({
    super.key,
    required this.readiness,
    required this.onGrant,
    required this.onOpenAppSettings,
    required this.onOpenLocationSettings,
    required this.onRecheck,
    this.busy = false,
  });

  final LocationReadiness readiness;

  /// Ask the OS. Only meaningful for [LocationReadiness.permissionDenied].
  final VoidCallback onGrant;
  final VoidCallback onOpenAppSettings;
  final VoidCallback onOpenLocationSettings;

  /// Re-read readiness — used by the manual retry. The form also re-checks on
  /// app resume, which is what catches a change the user made in Settings.
  final VoidCallback onRecheck;

  final bool busy;

  String get _title => switch (readiness) {
    LocationReadiness.serviceDisabled => sdkTr('Turn on location'),
    _ => sdkTr('Location permission required'),
  };

  String get _message => switch (readiness) {
    LocationReadiness.serviceDisabled => sdkTr(
      'This device\'s location is switched off, so this record cannot store '
      'where it was collected. Turn location on to continue.',
    ),
    LocationReadiness.permissionBlocked => sdkTr(
      'Location permission is blocked for this app, so it can no longer be '
      'requested here. Open Settings and allow location to continue.',
    ),
    _ => sdkTr(
      'Every new record stores where it was collected, so location access is '
      'needed before you can fill this form in.',
    ),
  };

  String get _actionLabel => switch (readiness) {
    LocationReadiness.serviceDisabled => sdkTr('Open location settings'),
    LocationReadiness.permissionBlocked => sdkTr('Open settings'),
    _ => sdkTr('Allow location'),
  };

  VoidCallback get _action => switch (readiness) {
    LocationReadiness.serviceDisabled => onOpenLocationSettings,
    LocationReadiness.permissionBlocked => onOpenAppSettings,
    _ => onGrant,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      // Opaque, and hit-test opaque, so a stray tap cannot reach the form
      // beneath it. NOT wrapped in an AbsorbPointer: that would swallow this
      // barrier's OWN buttons and leave the user with no way forward. The form
      // underneath is disabled by the caller instead.
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: ColoredBox(
          color: theme.colorScheme.surface,
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    readiness == LocationReadiness.serviceDisabled
                        ? Icons.location_off
                        : Icons.location_disabled,
                    size: 56,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('location_barrier_action'),
                      onPressed: busy ? null : _action,
                      icon: busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.my_location, size: 18),
                      label: Text(_actionLabel),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const Key('location_barrier_recheck'),
                    onPressed: busy ? null : onRecheck,
                    child: Text(sdkTr('I\'ve allowed it — check again')),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    sdkTr('Go back to leave this record without saving.'),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
