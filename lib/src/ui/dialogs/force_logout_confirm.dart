import 'package:flutter/material.dart';

/// Hard-gate dialog shown after the user picks `Log out anyway` in
/// [showLogoutGuardDialog]. The user must type `LOGOUT` (case-sensitive,
/// trimmed) before the destructive button activates. Spec §7.2 + §7.5.
///
/// Returns true if the user confirmed; false on Cancel or back-button.
/// Caller is responsible for actually running the logout + AtomicWipe
/// sequence.
Future<bool> showForceLogoutConfirm(
  BuildContext ctx, {
  required Map<String, int> perDoctypeCounts,
}) async {
  final r = await showDialog<bool>(
    context: ctx,
    builder: (c) => _ForceLogoutDialog(perDoctypeCounts: perDoctypeCounts),
  );
  return r ?? false;
}

class _ForceLogoutDialog extends StatefulWidget {
  final Map<String, int> perDoctypeCounts;
  const _ForceLogoutDialog({required this.perDoctypeCounts});
  @override
  State<_ForceLogoutDialog> createState() => _ForceLogoutDialogState();
}

class _ForceLogoutDialogState extends State<_ForceLogoutDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final total =
        widget.perDoctypeCounts.values.fold<int>(0, (a, b) => a + b);
    return AlertDialog(
      title: Text('Lose $total unsynced records?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
              'This permanently deletes records that were never synced:'),
          const SizedBox(height: 8),
          ...widget.perDoctypeCounts.entries
              .map((e) => Text('  • ${e.key}: ${e.value}')),
          const SizedBox(height: 12),
          const Text('Type LOGOUT to confirm.'),
          const SizedBox(height: 4),
          TextField(
            controller: _ctl,
            onChanged: (_) => setState(() {}),
            decoration:
                const InputDecoration(border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _ctl.text.trim() == 'LOGOUT'
              ? () => Navigator.pop(ctx, true)
              : null,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Logout & Wipe'),
        ),
      ],
    );
  }
}
