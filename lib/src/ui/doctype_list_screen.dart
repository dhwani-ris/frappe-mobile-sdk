import 'package:flutter/material.dart';
import '../models/app_config.dart';
import '../services/offline_repository.dart';

enum HomeScreenLayout { list, folder }

/// Screen showing list of Doctypes (from [doctypes] or [appConfig.doctypes]).
/// When using login response, pass [doctypes] from [MetaService.getMobileFormDoctypeNames()].
class DoctypeListScreen extends StatefulWidget {
  final AppConfig appConfig;
  final OfflineRepository repository;
  final Function(String doctype) onDoctypeSelected;
  final Function(String doctype)? onNewDocument;

  /// When set, used instead of appConfig.doctypes (e.g. from login / getMobileFormDoctypeNames).
  final List<String>? doctypes;
  final Map<String, List<String>>? groupedDoctypes;
  final HomeScreenLayout homeScreenLayout;

  const DoctypeListScreen({
    super.key,
    required this.appConfig,
    required this.repository,
    required this.onDoctypeSelected,
    this.onNewDocument,
    this.doctypes,
    this.groupedDoctypes,
    this.homeScreenLayout = HomeScreenLayout.list,
  });

  @override
  State<DoctypeListScreen> createState() => _DoctypeListScreenState();
}

class _DoctypeListScreenState extends State<DoctypeListScreen> {
  final Map<String, int> _documentCounts = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadDocumentCounts();
  }

  @override
  void didUpdateWidget(covariant DoctypeListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final groupsChanged = oldWidget.groupedDoctypes != widget.groupedDoctypes;
    final doctypesChanged = oldWidget.doctypes != widget.doctypes;
    if (groupsChanged || doctypesChanged) {
      _loadDocumentCounts();
    }
  }

  List<String> get _doctypes => widget.doctypes ?? widget.appConfig.doctypes;
  Map<String, List<String>> get _groups => widget.groupedDoctypes ?? const {};
  List<String> get _allDoctypesForCount {
    if (_groups.isNotEmpty) {
      return _groups.values.expand((e) => e).toSet().toList();
    }
    return _doctypes;
  }

  Future<void> _loadDocumentCounts() async {
    setState(() {
      _isLoading = true;
    });

    try {
      for (final doctype in _allDoctypesForCount) {
        final docs = await widget.repository.getDocumentsByDoctype(doctype);
        _documentCounts[doctype] = docs.length;
      }
    } catch (e) {
      // Ignore errors
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = _doctypes;
    final groups = _groups;
    return Scaffold(
      appBar: AppBar(title: const Text('Doctypes')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
          ? const Center(child: Text('No doctypes configured'))
          : widget.homeScreenLayout == HomeScreenLayout.folder
          ? ListView(
              children: [
                for (final entry
                    in (groups.isNotEmpty
                        ? groups.entries
                        : {'Other': list}.entries))
                  Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: ExpansionTile(
                      initiallyExpanded: true,
                      leading: const Icon(Icons.folder, color: Colors.blue),
                      title: Text(entry.key),
                      subtitle: Text('${entry.value.length} form(s)'),
                      children: [
                        for (final doctype in entry.value)
                          ListTile(
                            leading: const Icon(Icons.description),
                            title: Text(doctype),
                            subtitle: Text(
                              '${_documentCounts[doctype] ?? 0} document${(_documentCounts[doctype] ?? 0) != 1 ? 's' : ''}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.onNewDocument != null)
                                  IconButton(
                                    icon: const Icon(Icons.add),
                                    onPressed: () =>
                                        widget.onNewDocument!(doctype),
                                    tooltip: 'New document',
                                  ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                            onTap: () => widget.onDoctypeSelected(doctype),
                          ),
                      ],
                    ),
                  ),
              ],
            )
          : ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, index) {
                final doctype = list[index];
                final count = _documentCounts[doctype] ?? 0;

                return ListTile(
                  leading: const Icon(Icons.description),
                  title: Text(doctype),
                  subtitle: Text('$count document${count != 1 ? 's' : ''}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onNewDocument != null)
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () => widget.onNewDocument!(doctype),
                          tooltip: 'New document',
                        ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () => widget.onDoctypeSelected(doctype),
                );
              },
            ),
    );
  }
}
