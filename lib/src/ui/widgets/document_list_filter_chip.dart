import 'package:flutter/material.dart';

/// Tri-state filter for the document list. Spec §7.2.
///
/// - `all`: every row that resolves through `OfflineRepository.query` —
///   includes pulled (`synced`) rows + offline edits (`dirty`,
///   `blocked`, `conflict`). `failed` rows are excluded by default.
/// - `unsynced`: just the offline-edited subset (`dirty`, `blocked`,
///   `conflict`).
/// - `errors`: just the error states (`failed`, `conflict`) — opens
///   the SyncErrorsScreen affordances.
enum DocumentListFilter { all, unsynced, errors }

class DocumentListFilterCounts {
  final int all;
  final int unsynced;
  final int errors;
  const DocumentListFilterCounts({
    required this.all,
    required this.unsynced,
    required this.errors,
  });
}

/// Material `SegmentedButton` chip showing the three filter buckets and
/// their counts. Stateless — caller owns the [value] and listens to
/// [onChanged] for selection updates.
class DocumentListFilterChip extends StatelessWidget {
  final DocumentListFilterCounts counts;
  final DocumentListFilter value;
  final ValueChanged<DocumentListFilter> onChanged;

  const DocumentListFilterChip({
    super.key,
    required this.counts,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DocumentListFilter>(
      segments: [
        ButtonSegment(
          value: DocumentListFilter.all,
          label: Text('All ${counts.all}'),
        ),
        ButtonSegment(
          value: DocumentListFilter.unsynced,
          label: Text('Unsynced ${counts.unsynced}'),
        ),
        ButtonSegment(
          value: DocumentListFilter.errors,
          label: Text('Errors ${counts.errors}'),
        ),
      ],
      selected: {value},
      onSelectionChanged: (set) => onChanged(set.first),
    );
  }
}
