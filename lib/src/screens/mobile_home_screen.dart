// ignore_for_file: use_build_context_synchronously
import 'package:flutter/material.dart';
import '../sdk/frappe_sdk.dart';
import '../ui/document_list_screen.dart';

/// Generic home screen that renders doctype groups from the SDK's Mobile Configuration.
class MobileHomeScreen extends StatefulWidget {
  final FrappeSDK sdk;
  final String appTitle;
  final Future<void> Function()? onLogout;

  const MobileHomeScreen({
    super.key,
    required this.sdk,
    required this.appTitle,
    this.onLogout,
  });

  @override
  State<MobileHomeScreen> createState() => _MobileHomeScreenState();
}

class _MobileHomeScreenState extends State<MobileHomeScreen> {
  Map<String, List<String>> _groups = {};
  Map<String, int> _counts = {};
  Map<String, int> _dirtyCounts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final groups = await widget.sdk.meta.getMobileFormGroups();
      final counts = <String, int>{};
      final dirtyCounts = <String, int>{};

      for (final doctype in groups.values.expand((l) => l)) {
        try {
          final docs = await widget.sdk.repository.getDocumentsByDoctype(doctype);
          counts[doctype] = docs.length;
          dirtyCounts[doctype] = docs.where((d) => d.status == 'dirty').length;
        } catch (_) {
          counts[doctype] = 0;
          dirtyCounts[doctype] = 0;
        }
      }

      if (mounted) {
        setState(() {
          _groups = groups;
          _counts = counts;
          _dirtyCounts = dirtyCounts;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _navigateToDoctype(String doctype) async {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Loading...')),
    );
    try {
      final meta = await widget.sdk.meta.getMeta(doctype);
      final docs = await widget.sdk.repository.getDocumentsByDoctype(doctype);
      try {
        await widget.sdk.sync.pullSync(doctype: doctype);
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => DocumentListScreen(
              doctype: doctype,
              meta: meta,
              repository: widget.sdk.repository,
              syncService: widget.sdk.sync,
              metaService: widget.sdk.meta,
              linkOptionService: widget.sdk.linkOptions,
              api: widget.sdk.api,
              getMobileUuid: () async => '',
              initialDocuments: docs,
              userRoles: widget.sdk.roles,
              permissionService: widget.sdk.permissions,
              translate: (s) => widget.sdk.translations.translate(s),
            ),
          ),
        );
        _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: ${e.toString().split(':').last.trim()}'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  Future<void> _handleLogout() async {
    if (widget.onLogout != null) {
      await widget.onLogout!();
    } else {
      await widget.sdk.logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _handleLogout,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: Text('Loading...'))
            : _groups.isEmpty
                ? _buildEmptyState()
                : _buildGroupedList(),
      ),
    );
  }

  Widget _buildEmptyState() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: SizedBox(
        height: 300,
        child: const Center(
          child: Text(
            'No forms configured.\nPull down to refresh.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      ),
    );
  }

  Widget _buildGroupedList() {
    return ListView(
      children: _groups.entries.map((entry) {
        final groupName = entry.key;
        final doctypes = entry.value;
        final formsCount = doctypes.length;

        return ExpansionTile(
          initiallyExpanded: true,
          backgroundColor: const Color(0xFFB2DFDB),
          collapsedBackgroundColor: const Color(0xFFB2DFDB),
          shape: const Border(left: BorderSide(color: Color(0xFF00796B), width: 4)),
          collapsedShape: const Border(left: BorderSide(color: Color(0xFF00796B), width: 4)),
          title: Row(
            children: [
              Text(
                groupName,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF004D40),
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF00796B),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$formsCount ${formsCount == 1 ? 'form' : 'forms'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ],
          ),
          children: doctypes.map((doctype) => _buildDoctypeTile(doctype)).toList(),
        );
      }).toList(),
    );
  }

  Widget _buildDoctypeTile(String doctype) {
    final count = _counts[doctype] ?? 0;
    final dirty = _dirtyCounts[doctype] ?? 0;

    final String subtitle;
    final Color subtitleColor;
    if (dirty > 0) {
      subtitle = '↑ $dirty unsynced';
      subtitleColor = const Color(0xFFE65100);
    } else if (count > 0) {
      subtitle = '✓ all synced';
      subtitleColor = const Color(0xFF388E3C);
    } else {
      subtitle = 'No records yet';
      subtitleColor = Colors.grey;
    }

    final chipColor = count > 0 ? const Color(0xFFE0F2F1) : const Color(0xFFF5F5F5);
    final chipTextColor = count > 0 ? const Color(0xFF00796B) : Colors.grey;

    return ListTile(
      title: Text(
        doctype,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Color(0xFF212121),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 10, color: subtitleColor, fontWeight: FontWeight.w500),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: chipColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          '$count',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: chipTextColor),
        ),
      ),
      onTap: () => _navigateToDoctype(doctype),
    );
  }
}
