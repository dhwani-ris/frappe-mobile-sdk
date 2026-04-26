import 'package:flutter/material.dart';

import '../../models/outbox_row.dart';

/// List of currently-erroring outbox rows, grouped by doctype with
/// per-row Retry / View error / Open actions and a header `Retry all`
/// button. Spec §7.2.
///
/// Stateless — caller owns the row list and the action callbacks. Wire
/// to [SyncController.pendingErrors], `.retry`, `.retryAll`, `.cancel`.
/// `retryAllRunning` disables per-row Retry buttons (as the engine
/// drains the queue in priority order) and swaps the header button
/// from `Retry all` → `Stop`.
class SyncErrorsScreen extends StatelessWidget {
  final List<OutboxRow> rows;
  final Future<void> Function(int outboxId) onRetry;
  final Future<void> Function() onRetryAll;
  final Future<void> Function() onStop;
  final void Function(OutboxRow) onOpen;
  final void Function(OutboxRow) onViewError;
  final bool retryAllRunning;

  const SyncErrorsScreen({
    super.key,
    required this.rows,
    required this.onRetry,
    required this.onRetryAll,
    required this.onStop,
    required this.onOpen,
    required this.onViewError,
    required this.retryAllRunning,
  });

  @override
  Widget build(BuildContext context) {
    final byDoctype = <String, List<OutboxRow>>{};
    for (final r in rows) {
      byDoctype.putIfAbsent(r.doctype, () => []).add(r);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync errors'),
        actions: [
          if (retryAllRunning)
            TextButton(onPressed: onStop, child: const Text('Stop'))
          else
            TextButton(
              onPressed: rows.isEmpty ? null : onRetryAll,
              child: const Text('Retry all'),
            ),
        ],
      ),
      body: ListView(
        children: byDoctype.entries.map((e) {
          return ExpansionTile(
            initiallyExpanded: true,
            title: Text('${e.key} (${e.value.length})'),
            children: e.value.map((r) {
              return ListTile(
                title: Text(r.mobileUuid),
                subtitle: Text(
                  '${r.errorCode?.name ?? ""} · ${r.errorMessage ?? ""}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    OutlinedButton(
                      onPressed:
                          retryAllRunning ? null : () => onRetry(r.id),
                      child: const Text('Retry'),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.info_outline),
                      tooltip: 'View error',
                      onPressed: () => onViewError(r),
                    ),
                    IconButton(
                      icon: const Icon(Icons.open_in_new),
                      tooltip: 'Open',
                      onPressed: () => onOpen(r),
                    ),
                  ],
                ),
              );
            }).toList(),
          );
        }).toList(),
      ),
    );
  }
}
