import 'package:flutter/material.dart';

import '../../models/outbox_row.dart';

/// Human-readable surface for a stuck outbox row. The first element of
/// the record (`headline`) is the one-line summary shown collapsed; the
/// second (`detail`) is the longer technical description shown when the
/// banner is expanded. Both are designed to be safe to show users —
/// raw exception strings are never returned here, only mapped.
typedef OutboxErrorText = ({String headline, String detail});

/// Pulls the user-meaningful first line out of an outbox error message.
///
/// Server payloads often look like:
///   `ValidationException: Could not find Row #1: Name of Learner: <uuid>. Errors: {exception: ...}`
/// The bit *before* `. Errors:` is the actual message; everything after
/// is server-side debug noise (traceback, exc_type, _server_messages).
/// This function pulls out that leading sentence and strips common
/// Frappe / Python prefixes so the headline reads cleanly.
///
/// Returns the empty string when nothing useful can be extracted —
/// callers should fall back to a canned headline in that case.
String _extractFirstUsefulLine(String raw) {
  if (raw.isEmpty) return '';
  var s = raw;

  // Cut off the structured trailer Frappe attaches after the first
  // sentence: ". Errors: {...}" or "\nTraceback...".
  for (final sep in const ['. Errors:', '\nTraceback', '. Traceback']) {
    final idx = s.indexOf(sep);
    if (idx >= 0) {
      s = s.substring(0, idx);
      break;
    }
  }
  // Then take just the first line.
  final nl = s.indexOf('\n');
  if (nl >= 0) s = s.substring(0, nl);
  s = s.trim();

  // Strip common exception prefixes so the user sees the message, not
  // the wrapper class.
  for (final prefix in const [
    'ValidationException: ',
    'LinkValidationError: ',
    'frappe.exceptions.LinkValidationError: ',
    'frappe.exceptions.ValidationError: ',
    'MandatoryError: ',
    'PermissionError: ',
    'TimestampMismatchError: ',
    'Exception: ',
    'ApiException: ',
  ]) {
    if (s.startsWith(prefix)) {
      s = s.substring(prefix.length);
      break;
    }
  }

  // A trailing period reads odd as a headline — drop it.
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s.trim();
}

/// Maps an outbox row's `(state, errorCode)` pair to plain-language
/// strings. Keep this pure and side-effect-free — callers expect to be
/// able to call it from a widget `build` method.
OutboxErrorText humanizeOutboxError(OutboxRow row) {
  final code = row.errorCode;
  final raw = (row.errorMessage ?? '').trim();
  final firstLine = _extractFirstUsefulLine(raw);

  String headline;
  String detail;

  switch (row.state) {
    case OutboxState.blocked:
      headline = firstLine.isNotEmpty
          ? firstLine
          : 'Waiting for a related record to sync';
      detail = raw.isEmpty
          ? 'Another record this one depends on has not reached the server yet. '
                'It will sync automatically once that record goes through.'
          : raw;
      break;

    case OutboxState.conflict:
      headline = firstLine.isNotEmpty
          ? firstLine
          : 'This record was changed elsewhere';
      detail = raw.isEmpty
          ? 'Someone else updated this record on the server while your '
                'changes were offline. Resolve the conflict to continue.'
          : raw;
      break;

    case OutboxState.failed:
      // Prefer the server's own one-liner whenever we got one — it is
      // far more actionable ("Could not find Row #1: Name of Learner: …")
      // than any canned copy. Fall back to the canned headline only
      // when [errorMessage] is empty or didn't yield a usable line.
      String fallback;
      String fallbackDetail;
      switch (code) {
        case ErrorCode.NETWORK:
        case ErrorCode.TIMEOUT:
          fallback = 'Could not reach the server';
          fallbackDetail =
              'The device could not connect long enough to '
              'push this record. It will retry automatically when the '
              'connection is stable.';
          break;
        case ErrorCode.VALIDATION:
        case ErrorCode.MANDATORY:
          fallback = 'The server rejected this change';
          fallbackDetail =
              'The record is missing required information or '
              'failed a validation rule. Open and edit it to fix the issue.';
          break;
        case ErrorCode.LINK_EXISTS:
          fallback = 'A linked record is missing on the server';
          fallbackDetail =
              'A field that links to another record points to '
              'something the server cannot find.';
          break;
        case ErrorCode.PERMISSION_DENIED:
          fallback = "You don't have permission to save this";
          fallbackDetail =
              'Your account is not allowed to create or modify '
              'this record. Contact your administrator.';
          break;
        case ErrorCode.TIMESTAMP_MISMATCH:
          fallback = 'This record was changed elsewhere';
          fallbackDetail =
              'The server has a newer version of this record '
              'than what was saved offline.';
          break;
        case ErrorCode.UNKNOWN:
        case null:
          fallback = 'Sync failed';
          fallbackDetail =
              'The server refused this change for an '
              'unspecified reason.';
          break;
      }
      headline = firstLine.isNotEmpty ? firstLine : fallback;
      detail = raw.isEmpty ? fallbackDetail : raw;
      break;

    case OutboxState.pending:
    case OutboxState.inFlight:
    case OutboxState.done:
      headline = 'Sync in progress';
      detail = raw.isEmpty ? 'This record is being synced.' : raw;
      break;
  }

  return (headline: headline, detail: detail);
}

/// Foreground/background colour pair for an outbox row, picked from the
/// active theme so consumer apps that override `colorScheme` get matching
/// banners without having to restyle this widget.
({Color bg, Color fg, IconData icon}) _palette(
  BuildContext context,
  OutboxState state,
) {
  final cs = Theme.of(context).colorScheme;
  switch (state) {
    case OutboxState.blocked:
      return (
        bg: const Color(0xFFFFF8E1),
        fg: const Color(0xFF8D6E00),
        icon: Icons.hourglass_top_outlined,
      );
    case OutboxState.conflict:
      return (
        bg: const Color(0xFFFFEBEE),
        fg: const Color(0xFFC62828),
        icon: Icons.merge_type,
      );
    case OutboxState.failed:
      return (
        bg: const Color(0xFFFFEBEE),
        fg: const Color(0xFFC62828),
        icon: Icons.error_outline,
      );
    case OutboxState.pending:
    case OutboxState.inFlight:
    case OutboxState.done:
      return (
        bg: cs.surfaceContainerHighest,
        fg: cs.onSurfaceVariant,
        icon: Icons.sync,
      );
  }
}

/// A persistent in-form banner that surfaces stuck sync state for the
/// document currently being viewed. Renders one card per outbox row in
/// `failed`, `blocked`, or `conflict` — collapsed shows the human-readable
/// headline, expanded reveals the raw error code, message, last-attempt
/// timestamp, and retry count plus a `Retry` action.
///
/// The widget is stateless w.r.t. the outbox (parent owns the row list
/// and reload semantics). Parents typically refetch and rebuild after
/// `onRetry` resolves.
class SyncErrorBanner extends StatefulWidget {
  /// All rows to display. Treat this list as already filtered to user-
  /// actionable states (failed/blocked/conflict) — see
  /// [OfflineRepository.getSyncErrorsForDoc].
  final List<OutboxRow> rows;

  /// Tapping the per-row Retry button calls this. When null, the button
  /// is hidden so the banner stays informational. The future should
  /// resolve once the SDK has flipped the row back to `pending`.
  final Future<void> Function(int outboxId)? onRetry;

  const SyncErrorBanner({super.key, required this.rows, this.onRetry});

  @override
  State<SyncErrorBanner> createState() => _SyncErrorBannerState();
}

class _SyncErrorBannerState extends State<SyncErrorBanner> {
  final Set<int> _expanded = <int>{};
  final Set<int> _retrying = <int>{};

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [for (final r in widget.rows) _buildRow(context, r)],
    );
  }

  Widget _buildRow(BuildContext context, OutboxRow row) {
    final p = _palette(context, row.state);
    final text = humanizeOutboxError(row);
    final isExpanded = _expanded.contains(row.id);
    final isRetrying = _retrying.contains(row.id);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 1),
      color: p.bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expanded.remove(row.id);
                } else {
                  _expanded.add(row.id);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Icon(p.icon, color: p.fg, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text.headline,
                      style: TextStyle(
                        color: p.fg,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(Icons.expand_more, color: p.fg, size: 20),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(42, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Detail can be a multi-KB Frappe traceback. Cap its
                  // visible height so a long stack trace can't drag the
                  // whole banner past the screen — overflow scrolls
                  // inside this region instead.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: Scrollbar(
                      child: SingleChildScrollView(
                        primary: false,
                        child: SelectableText(
                          text.detail,
                          style: TextStyle(
                            color: p.fg,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _DetailGrid(
                    state: row.state.wireName,
                    operation: row.operation.wireName,
                    errorCode: row.errorCode?.name,
                    retryCount: row.retryCount,
                    lastAttemptAt: row.lastAttemptAt,
                    fg: p.fg,
                  ),
                  if (widget.onRetry != null) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: p.fg,
                          side: BorderSide(color: p.fg.withValues(alpha: 0.4)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                        ),
                        onPressed: isRetrying ? null : () => _handleRetry(row),
                        icon: isRetrying
                            ? SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: p.fg,
                                ),
                              )
                            : Icon(Icons.refresh, size: 16, color: p.fg),
                        label: Text(isRetrying ? 'Retrying…' : 'Retry'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _handleRetry(OutboxRow row) async {
    final fn = widget.onRetry;
    if (fn == null) return;
    setState(() => _retrying.add(row.id));
    try {
      await fn(row.id);
    } finally {
      if (mounted) setState(() => _retrying.remove(row.id));
    }
  }
}

class _DetailGrid extends StatelessWidget {
  final String state;
  final String operation;
  final String? errorCode;
  final int retryCount;
  final DateTime? lastAttemptAt;
  final Color fg;

  const _DetailGrid({
    required this.state,
    required this.operation,
    required this.errorCode,
    required this.retryCount,
    required this.lastAttemptAt,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    final muted = fg.withValues(alpha: 0.7);
    final rows = <List<String>>[
      ['Status', state],
      ['Operation', operation],
      if (errorCode != null) ['Error code', errorCode!],
      ['Retry attempts', '$retryCount'],
      if (lastAttemptAt != null) ['Last attempt', _formatTime(lastAttemptAt!)],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    r[0],
                    style: TextStyle(
                      color: muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(r[1], style: TextStyle(color: fg, fontSize: 11)),
                ),
              ],
            ),
          ),
      ],
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    String two(int x) => x.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
