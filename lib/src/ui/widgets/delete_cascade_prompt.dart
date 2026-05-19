import 'package:flutter/material.dart';

/// Choice from [showDeleteCascadePrompt]. Spec §7.2.
///
/// - [deleteAll]: enqueue DELETE outbox rows for every dependent BEFORE
///   the original parent's row, with `created_at` strictly earlier so
///   tier computation dispatches dependents first. The parent's DELETE
///   is retried last.
/// - [fixManually]: open SyncErrorsScreen so the user can resolve the
///   blockers individually.
/// - [cancel]: dismiss; row stays in `failed(LINK_EXISTS)`.
enum DeleteCascadeAction { deleteAll, fixManually, cancel }

/// Shown when a DELETE push fails with `LinkExistsError`. Lists every
/// dependent doctype + count so the user can decide whether to cascade
/// the delete or fix manually.
Future<DeleteCascadeAction> showDeleteCascadePrompt(
  BuildContext ctx, {
  required String rootName,
  required Map<String, List<String>> blockedBy,
}) async {
  final r = await showDialog<DeleteCascadeAction>(
    context: ctx,
    builder: (c) => AlertDialog(
      title: Text("Cannot delete '$rootName'"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This record is linked to other records:'),
          const SizedBox(height: 8),
          ...blockedBy.entries
              .map((e) => Text('  • ${e.key}: ${e.value.length}')),
          const SizedBox(height: 12),
          const Text('Delete all of these too?'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, DeleteCascadeAction.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(c, DeleteCascadeAction.fixManually),
          child: const Text('Fix manually'),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.pop(c, DeleteCascadeAction.deleteAll),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Delete all'),
        ),
      ],
    ),
  );
  return r ?? DeleteCascadeAction.cancel;
}
