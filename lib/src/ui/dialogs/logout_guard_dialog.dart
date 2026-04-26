import 'package:flutter/material.dart';

/// User's choice from the [showLogoutGuardDialog]. Spec §7.2.
///
/// - [syncNow]: kick off `SyncController.syncNow()`, then re-prompt
///   if anything is still pending.
/// - [logoutAnyway]: open the [showForceLogoutConfirm] gate.
/// - [cancel]: dismiss; user stays logged in.
enum LogoutGuardAction { syncNow, logoutAnyway, cancel }

/// Soft-gate dialog shown when the user taps Logout while there are
/// unsynced rows. Returns `cancel` if the dialog is dismissed without
/// a choice (back-button or scrim tap).
Future<LogoutGuardAction> showLogoutGuardDialog(
  BuildContext ctx, {
  required int unsyncedCount,
}) async {
  final r = await showDialog<LogoutGuardAction>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: const Text('You have unsynced changes'),
      content: Text(
        '$unsyncedCount unsynced records haven\'t been pushed to the '
        'server.\n\nSync now or log out anyway (you\'ll lose these '
        'changes).',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, LogoutGuardAction.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(c, LogoutGuardAction.logoutAnyway),
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('Log out anyway'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(c, LogoutGuardAction.syncNow),
          child: const Text('Sync now'),
        ),
      ],
    ),
  );
  return r ?? LogoutGuardAction.cancel;
}
