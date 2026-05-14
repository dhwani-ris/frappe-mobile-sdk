import 'package:flutter/material.dart';

/// Severity buckets for [showStatusSnackBar]. Maps to background colors
/// used historically across the SDK's screens — success (green), error
/// (red), warning (orange), info (blue/default). Centralised so a future
/// theme switch (e.g. routing through `Theme.of(context).colorScheme`)
/// updates every snackbar at once.
enum SnackBarSeverity { success, error, warning, info }

/// Single canonical SnackBar emit used by every SDK screen / dialog
/// (mobile_home_screen, form_screen, sync_status_screen, child_table
/// error path, etc.). Replaces 17+ hand-written
/// `showSnackBar(SnackBar(content: Text(...), backgroundColor: ...))`
/// call sites. Pass [severity] to pick a color from the SDK palette, or
/// [backgroundColor] to override with a specific value (used by sites
/// that historically used non-Material colors like deep-orange `#E65100`
/// — passing the literal preserves the original visual exactly).
///
/// Every snackbar emitted through this helper carries a `DISMISS` action
/// so the user can clear it without waiting for the duration to elapse
/// (Flutter's default swipe-down dismissal isn't discoverable). Pass
/// [showDismissAction] = false to suppress, e.g. for purely transient
/// notifications where the duration is short and a button is noise.
void showStatusSnackBar(
  BuildContext context,
  String message, {
  SnackBarSeverity severity = SnackBarSeverity.info,
  Color? backgroundColor,
  Duration? duration,
  bool showDismissAction = true,
}) {
  Color? bg = backgroundColor;
  if (bg == null) {
    switch (severity) {
      case SnackBarSeverity.success:
        bg = Colors.green;
      case SnackBarSeverity.error:
        bg = Colors.red;
      case SnackBarSeverity.warning:
        bg = Colors.orange;
      case SnackBarSeverity.info:
        bg = null;
    }
  }
  // Tapping a SnackBarAction auto-dismisses the snackbar before the
  // onPressed callback runs (Flutter framework contract), so an empty
  // onPressed is the canonical "dismiss-only" wiring. `textColor: white`
  // ensures the label is readable on colored backgrounds; with neutral
  // (null bg) Flutter's default action color picks up the theme accent.
  final action = showDismissAction
      ? SnackBarAction(
          label: 'DISMISS',
          textColor: bg != null ? Colors.white : null,
          onPressed: () {},
        )
      : null;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: bg,
      duration: duration ?? const Duration(seconds: 4),
      action: action,
    ),
  );
}

/// Confirmation dialog with Cancel + destructive-action buttons. Returns
/// true when the user picks the destructive action, false on Cancel, null
/// if dismissed via the OS back gesture. Shared by every destructive flow
/// (logout, force re-sync, delete document, force-exit-offline) so the
/// dialog scaffolding lives in one place.
Future<bool?> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  Color? confirmColor,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(
            confirmLabel,
            style: confirmColor != null ? TextStyle(color: confirmColor) : null,
          ),
        ),
      ],
    ),
  );
}

/// AppBar action that renders a refresh icon when idle and a centered
/// spinner when busy. Shared by `document_list_screen.dart` and
/// `sync_status_screen.dart`.
Widget refreshOrSpinnerAction({
  required bool isBusy,
  required VoidCallback onRefresh,
  String tooltip = 'Refresh',
}) {
  if (isBusy) {
    return const Padding(
      padding: EdgeInsets.all(16.0),
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
  return IconButton(
    icon: const Icon(Icons.refresh),
    onPressed: onRefresh,
    tooltip: tooltip,
  );
}

/// Standard empty-state widget used by every SDK list screen: centered
/// column with an icon, a title, an optional subtitle, and an optional
/// trailing action. Shared by `mobile_home_screen`, `document_list_screen`,
/// `sync_status_screen`, `sync_errors_screen`.
class EmptyStateWidget extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;
  final Color? iconColor;

  /// Optional style for the title. Defaults to `theme.textTheme.titleMedium`.
  final TextStyle? titleStyle;

  /// Optional style for the subtitle. Defaults to
  /// `theme.textTheme.bodyMedium?.copyWith(color: Colors.grey[600])`.
  /// Override at the call site when the historical inline style differed
  /// (e.g. `bodySmall` for compact lists, `onSurfaceVariant` for theme
  /// adaptiveness in dark mode).
  final TextStyle? subtitleStyle;

  const EmptyStateWidget({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
    this.iconColor,
    this.titleStyle,
    this.subtitleStyle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: iconColor ?? Colors.grey),
            const SizedBox(height: 16),
            Text(title, style: titleStyle ?? theme.textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style:
                    subtitleStyle ??
                    theme.textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

/// Modal loading overlay. Pushes a non-dismissible dialog showing a
/// centered spinner; returns a `VoidCallback` the caller invokes to
/// dismiss. Replaces the inline `showDialog(barrierDismissible: false,
/// ProgressIndicator)` pattern used at `mobile_home_screen.dart:517`
/// and `:573` for logout / force-resync flows.
VoidCallback showLoadingDialog(BuildContext context) {
  bool dismissed = false;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  return () {
    if (dismissed) return;
    dismissed = true;
    // Match the historical inline call (`Navigator.of(context).pop()`) so
    // existing nested-navigator semantics are preserved exactly.
    Navigator.of(context).pop();
  };
}

/// Inline error banner — red Container + icon + message — used by
/// `login_screen.dart` and `form_screen.dart`. Login adds rounded corners
/// + border; form-screen does not. Pass `bordered: true` for the login
/// style, false (default) for the form-screen style.
class ErrorMessageBanner extends StatelessWidget {
  final String message;
  final bool bordered;
  final Color? backgroundColor;

  const ErrorMessageBanner({
    super.key,
    required this.message,
    this.bordered = false,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ?? Colors.red[50];
    return Container(
      width: bordered ? null : double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: bordered
          ? BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.red),
            )
          : null,
      color: bordered ? null : bg,
      child: Row(
        children: [
          const Icon(Icons.error, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
