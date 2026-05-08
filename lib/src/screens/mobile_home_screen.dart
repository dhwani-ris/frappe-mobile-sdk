// ignore_for_file: use_build_context_synchronously
import 'dart:async';

import 'package:flutter/material.dart';
import '../models/link_filter_result.dart';
import '../sdk/frappe_sdk.dart';
import '../ui/document_list_screen.dart';
import '../ui/widgets/form_builder.dart' show FieldChangeHandler;

/// Generic home screen that renders doctype groups from the SDK's Mobile Configuration.
///
/// All colors are derived from [Theme.of(context).colorScheme]. Consuming apps
/// control appearance by providing a [ThemeData] with a custom [ColorScheme].
class MobileHomeScreen extends StatefulWidget {
  final FrappeSDK sdk;
  final String appTitle;

  /// Called after the SDK completes logout. Use this to update your app's
  /// auth state (e.g. `setState(() => _isAuthenticated = false)`).
  final Future<void> Function()? onLogout;

  /// Optional callback when sync button is pressed. If null, default
  /// push+pull sync is performed.
  final Future<void> Function()? onSyncPressed;

  /// Optional builder to replace the default group header.
  /// Renders inside the tinted header row of each group card.
  final Widget Function(BuildContext context, String groupName, int formsCount)?
  groupHeaderBuilder;

  /// Optional builder to replace the default doctype tile.
  /// Renders as a child in a Column with dividers (no need to add dividers).
  ///
  /// `errorCount` is the number of stuck outbox rows for this doctype
  /// (failed/blocked/conflict). Apps customizing the tile should
  /// surface it visibly — the default tile renders a red `⚠ N error`
  /// segment when `errorCount > 0`.
  final Widget Function(
    BuildContext context,
    String doctype,
    int count,
    int dirtyCount,
    int errorCount,
  )?
  tileBuilder;

  /// Optional resolver that returns a per-doctype onFieldChange callback.
  /// Use this to inject app-level form event logic (e.g. cascading clears)
  /// without subclassing. Return null for doctypes that need no custom handling.
  ///
  /// Example:
  /// ```dart
  /// getFieldChangeHandler: (doctype) =>
  ///     FormHandlers.forDoctype(doctype)?.onFieldChange,
  /// ```
  final FieldChangeHandler? Function(String doctype)? getFieldChangeHandler;

  /// Optional builder for runtime link filters. Called during link option resolution.
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
  getLinkFilterBuilder;

  const MobileHomeScreen({
    super.key,
    required this.sdk,
    required this.appTitle,
    this.onLogout,
    this.onSyncPressed,
    this.groupHeaderBuilder,
    this.tileBuilder,
    this.getFieldChangeHandler,
    this.getLinkFilterBuilder,
  });

  @override
  State<MobileHomeScreen> createState() => _MobileHomeScreenState();
}

class _MobileHomeScreenState extends State<MobileHomeScreen>
    with SingleTickerProviderStateMixin {
  Map<String, List<String>> _groups = {};
  Map<String, int> _counts = {};
  Map<String, int> _dirtyCounts = {};
  Map<String, int> _errorCounts = {};
  bool _loading = true;
  bool _isSyncing = false;
  bool _isForceSyncing = false;
  bool _isOnline = false;

  StreamSubscription<void>? _syncSub;
  late final AnimationController _syncIconController;

  @override
  void initState() {
    super.initState();
    _syncIconController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _syncSub = widget.sdk.syncComplete$?.listen((_) {
      if (mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _syncIconController.dispose();
    super.dispose();
  }

  int get _totalDirty => _dirtyCounts.values.fold(0, (a, b) => a + b);
  int get _totalErrors => _errorCounts.values.fold(0, (a, b) => a + b);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Fire connectivity check without blocking — update UI when it resolves
      widget.sdk.sync
          .isOnline()
          .then((online) {
            if (mounted) setState(() => _isOnline = online);
          })
          .catchError((_) {
            if (mounted) setState(() => _isOnline = false);
          });

      final groups = await widget.sdk.meta.getMobileFormGroups();
      final counts = <String, int>{};
      final dirtyCounts = <String, int>{};

      for (final doctype in groups.values.expand((l) => l)) {
        try {
          final results = await Future.wait([
            widget.sdk.resolver.count(doctype),
            widget.sdk.resolver.count(doctype, dirtyOnly: true),
          ]);
          counts[doctype] = results[0];
          dirtyCounts[doctype] = results[1];
        } catch (e, st) {
          // ignore: avoid_print
          print('MobileHomeScreen: count load for $doctype failed — $e\n$st');
          counts[doctype] = 0;
          dirtyCounts[doctype] = 0;
        }
      }

      // One pendingErrors() call covers every doctype — bucket by
      // doctype so each tile can surface its own error count.
      final errorCounts = <String, int>{};
      final controller = widget.sdk.syncController;
      if (controller != null) {
        try {
          final rows = await controller.pendingErrors();
          for (final r in rows) {
            errorCounts[r.doctype] = (errorCounts[r.doctype] ?? 0) + 1;
          }
        } catch (e, st) {
          // ignore: avoid_print
          print('MobileHomeScreen: pendingErrors load failed — $e\n$st');
        }
      }

      if (mounted) {
        setState(() {
          _groups = groups;
          _counts = counts;
          _dirtyCounts = dirtyCounts;
          _errorCounts = errorCounts;
          _loading = false;
        });
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('MobileHomeScreen: _load failed — $e\n$st');
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleSync() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);
    _syncIconController.repeat();
    try {
      if (widget.onSyncPressed != null) {
        await widget.onSyncPressed!();
      } else {
        try {
          await widget.sdk.sync.pushSync();
        } catch (e, st) {
          // ignore: avoid_print
          print('MobileHomeScreen: manual pushSync failed — $e\n$st');
        }
        final doctypes = await widget.sdk.meta.getMobileFormDoctypeNames();
        for (final dt in doctypes) {
          try {
            await widget.sdk.sync.pullSync(doctype: dt);
          } catch (e, st) {
            // ignore: avoid_print
            print('MobileHomeScreen: manual pullSync($dt) failed — $e\n$st');
          }
        }
      }
      await _load();
    } finally {
      if (mounted) {
        _syncIconController.stop();
        _syncIconController.reset();
        setState(() => _isSyncing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final userInfo = widget.sdk.currentUser;
    final initials = _getInitials(userInfo?.fullName ?? userInfo?.email ?? '?');

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.appTitle),
            const SizedBox(width: 8),
            _ConnectivityBadge(isOnline: _isOnline),
          ],
        ),
        actions: [
          if (_totalErrors > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFEBEE),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 12,
                        color: Color(0xFFC62828),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '$_totalErrors',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFC62828),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_totalDirty > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF3E0),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.arrow_upward,
                        size: 12,
                        color: Color(0xFFE65100),
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '$_totalDirty',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFE65100),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          IconButton(
            icon: RotationTransition(
              turns: _syncIconController,
              child: const Icon(Icons.sync),
            ),
            tooltip: 'Sync now',
            onPressed: _isSyncing ? null : _handleSync,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => _showProfileSheet(context),
              child: CircleAvatar(
                radius: 16,
                backgroundColor: cs.primaryContainer,
                child: Text(
                  initials,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _groups.isEmpty
            ? _buildEmptyState()
            : _buildGroupedList(),
      ),
    );
  }

  String _getInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) {
      return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
    }
    return name.isNotEmpty ? name[0].toUpperCase() : '?';
  }

  Widget _buildEmptyState() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 120),
        Center(
          child: Text(
            'No forms configured.\nPull down to refresh.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupedList() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _groups.length,
      itemBuilder: (context, index) {
        final entry = _groups.entries.elementAt(index);
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _GroupCard(
            groupName: entry.key,
            doctypes: entry.value,
            counts: _counts,
            dirtyCounts: _dirtyCounts,
            errorCounts: _errorCounts,
            onDoctypeTap: _navigateToDoctype,
            groupHeaderBuilder: widget.groupHeaderBuilder,
            tileBuilder: widget.tileBuilder,
          ),
        );
      },
    );
  }

  void _showProfileSheet(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final userInfo = widget.sdk.currentUser;
    final fullName = userInfo?.fullName ?? 'User';
    final email = userInfo?.email ?? '';
    final initials = _getInitials(fullName);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.outline.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: cs.primaryContainer,
                      child: Text(
                        initials,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fullName,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface,
                            ),
                          ),
                          if (email.isNotEmpty)
                            Text(
                              email,
                              style: TextStyle(
                                fontSize: 12,
                                color: cs.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.cloud_download_outlined),
                title: const Text('Force Re-Sync All'),
                subtitle: const Text('Re-download reference & master data'),
                enabled: !_isForceSyncing,
                onTap: () {
                  Navigator.pop(sheetContext);
                  _handleForcePullAll();
                },
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout, color: Color(0xFFD32F2F)),
                title: const Text(
                  'Logout',
                  style: TextStyle(
                    color: Color(0xFFD32F2F),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _handleLogout();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Logout',
              style: TextStyle(color: Color(0xFFD32F2F)),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await widget.sdk.logout();
    } catch (e, st) {
      // ignore: avoid_print
      print('MobileHomeScreen: logout failed — $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Logout warning: ${e.toString().split(':').last.trim()}',
            ),
            backgroundColor: const Color(0xFFE65100),
          ),
        );
      }
    } finally {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
      }
      if (widget.onLogout != null) {
        await widget.onLogout!();
      }
    }
  }

  Future<void> _handleForcePullAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Force Re-Sync All?'),
        content: const Text(
          'This re-downloads all reference and master data from scratch. '
          'Your unsynced form entries are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Re-Sync'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isForceSyncing = true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      await widget.sdk.forcePullAll();
    } catch (e, st) {
      // ignore: avoid_print
      print('MobileHomeScreen: forcePullAll failed — $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Re-sync failed: ${e.toString().split(':').last.trim()}',
            ),
            backgroundColor: const Color(0xFFE65100),
          ),
        );
      }
    } finally {
      if (mounted) {
        Navigator.of(context).pop(); // dismiss loading
        setState(() => _isForceSyncing = false);
      }
    }

    await _load();
  }

  Future<void> _navigateToDoctype(String doctype) async {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Loading...')));
    try {
      final meta = await widget.sdk.meta.getMeta(doctype);
      try {
        await widget.sdk.sync.pullSync(doctype: doctype);
      } catch (e, st) {
        // ignore: avoid_print
        print('MobileHomeScreen: navigate pullSync($doctype) failed — $e\n$st');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DocumentListScreen(
              doctype: doctype,
              meta: meta,
              repository: widget.sdk.repository,
              resolver: widget.sdk.resolver,
              syncService: widget.sdk.sync,
              metaService: widget.sdk.meta,
              linkOptionService: widget.sdk.linkOptions,
              api: widget.sdk.api,
              getMobileUuid: () async => '',
              userRoles: widget.sdk.roles,
              permissionService: widget.sdk.permissions,
              translate: (s) => widget.sdk.translations.translate(s),
              onFieldChange: widget.getFieldChangeHandler?.call(doctype),
              getLinkFilterBuilder: widget.getLinkFilterBuilder,
              syncController: widget.sdk.syncController,
            ),
          ),
        );
        _load();
      }
    } catch (e, st) {
      // ignore: avoid_print
      print('MobileHomeScreen: _navigateToDoctype failed — $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: ${e.toString().split(':').last.trim()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
} // End of _MobileHomeScreenState

class _GroupCard extends StatefulWidget {
  final String groupName;
  final List<String> doctypes;
  final Map<String, int> counts;
  final Map<String, int> dirtyCounts;
  final Map<String, int> errorCounts;
  final void Function(String doctype) onDoctypeTap;
  final Widget Function(BuildContext, String, int)? groupHeaderBuilder;
  final Widget Function(BuildContext, String, int, int, int)? tileBuilder;

  const _GroupCard({
    required this.groupName,
    required this.doctypes,
    required this.counts,
    required this.dirtyCounts,
    required this.errorCounts,
    required this.onDoctypeTap,
    this.groupHeaderBuilder,
    this.tileBuilder,
  });

  @override
  State<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<_GroupCard> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final formsCount = widget.doctypes.length;

    return Material(
      color: cs.surface,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline.withValues(alpha: 0.3)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  border: _expanded
                      ? Border(
                          bottom: BorderSide(
                            color: cs.outline.withValues(alpha: 0.2),
                          ),
                        )
                      : null,
                ),
                child: widget.groupHeaderBuilder != null
                    ? Row(
                        children: [
                          Expanded(
                            child: widget.groupHeaderBuilder!(
                              context,
                              widget.groupName,
                              formsCount,
                            ),
                          ),
                          _chevron(cs),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                Text(
                                  widget.groupName,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                    color: cs.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cs.primary,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    '$formsCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          _chevron(cs),
                        ],
                      ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: _expanded
                  ? Column(
                      children: [
                        for (int i = 0; i < widget.doctypes.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: 1,
                              thickness: 1,
                              color: cs.outline.withValues(alpha: 0.12),
                            ),
                          widget.tileBuilder != null
                              ? widget.tileBuilder!(
                                  context,
                                  widget.doctypes[i],
                                  widget.counts[widget.doctypes[i]] ?? 0,
                                  widget.dirtyCounts[widget.doctypes[i]] ?? 0,
                                  widget.errorCounts[widget.doctypes[i]] ?? 0,
                                )
                              : _DoctypeTile(
                                  doctype: widget.doctypes[i],
                                  count: widget.counts[widget.doctypes[i]] ?? 0,
                                  dirtyCount:
                                      widget.dirtyCounts[widget.doctypes[i]] ??
                                      0,
                                  errorCount:
                                      widget.errorCounts[widget.doctypes[i]] ??
                                      0,
                                  onTap: () =>
                                      widget.onDoctypeTap(widget.doctypes[i]),
                                ),
                        ],
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chevron(ColorScheme cs) {
    return AnimatedRotation(
      turns: _expanded ? 0.0 : -0.25,
      duration: const Duration(milliseconds: 200),
      child: Icon(
        Icons.expand_more,
        size: 20,
        color: cs.onPrimaryContainer.withValues(alpha: 0.6),
      ),
    );
  }
}

class _DoctypeTile extends StatelessWidget {
  final String doctype;
  final int count;
  final int dirtyCount;
  final int errorCount;
  final VoidCallback onTap;

  const _DoctypeTile({
    required this.doctype,
    required this.count,
    required this.dirtyCount,
    required this.errorCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final bool hasError = errorCount > 0;
    final bool hasUnsynced = dirtyCount > 0;

    final chipColor = hasError
        ? const Color(0xFFFFEBEE)
        : hasUnsynced
        ? const Color(0xFFFFF3E0)
        : cs.surfaceContainerHighest;
    final chipTextColor = hasError
        ? const Color(0xFFC62828)
        : hasUnsynced
        ? const Color(0xFFE65100)
        : count > 0
        ? cs.onSurface
        : cs.onSurface.withValues(alpha: 0.4);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doctype,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _Subtitle(
                    count: count,
                    dirtyCount: dirtyCount,
                    errorCount: errorCount,
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: chipColor,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: chipTextColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: cs.outline.withValues(alpha: 0.4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tile subtitle that composes up to three coloured segments \u2014 error
/// count, unsynced count, "all synced" / "no records yet" \u2014 separated
/// by middots. Error always wins as the dominant signal.
class _Subtitle extends StatelessWidget {
  final int count;
  final int dirtyCount;
  final int errorCount;

  const _Subtitle({
    required this.count,
    required this.dirtyCount,
    required this.errorCount,
  });

  @override
  Widget build(BuildContext context) {
    final segments = <_TextSegment>[];
    if (errorCount > 0) {
      segments.add(
        _TextSegment(
          '\u26a0 $errorCount error${errorCount == 1 ? '' : 's'}',
          const Color(0xFFC62828),
          FontWeight.w600,
        ),
      );
    }
    if (dirtyCount > 0) {
      segments.add(
        _TextSegment(
          '\u2191 $dirtyCount unsynced',
          const Color(0xFFE65100),
          FontWeight.w500,
        ),
      );
    }
    if (segments.isEmpty) {
      if (count > 0) {
        segments.add(
          const _TextSegment(
            '\u2713 all synced',
            Color(0xFF388E3C),
            FontWeight.w500,
          ),
        );
      } else {
        segments.add(
          const _TextSegment(
            'No records yet',
            Color(0xFF9E9E9E),
            FontWeight.w500,
          ),
        );
      }
    }
    return RichText(
      text: TextSpan(
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0)
              const TextSpan(
                text: ' \u00b7 ',
                style: TextStyle(fontSize: 11, color: Color(0xFFBDBDBD)),
              ),
            TextSpan(
              text: segments[i].text,
              style: TextStyle(
                fontSize: 11,
                color: segments[i].color,
                fontWeight: segments[i].weight,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TextSegment {
  final String text;
  final Color color;
  final FontWeight weight;
  const _TextSegment(this.text, this.color, this.weight);
}

class _ConnectivityBadge extends StatelessWidget {
  final bool isOnline;

  const _ConnectivityBadge({required this.isOnline});

  @override
  Widget build(BuildContext context) {
    final color = isOnline ? const Color(0xFF388E3C) : const Color(0xFFD32F2F);
    final bgColor = isOnline
        ? const Color(0xFFE8F5E9)
        : const Color(0xFFFFEBEE);
    final label = isOnline ? 'Online' : 'Offline';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
