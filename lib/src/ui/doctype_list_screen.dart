import 'package:flutter/material.dart';
import '../models/app_config.dart';
import '../services/offline_repository.dart';

/// Screen showing list of Doctypes (from [doctypes] or [appConfig.doctypes]).
/// When using login response, pass [doctypes] from [MetaService.getMobileFormDoctypeNames()].
class DoctypeListScreen extends StatefulWidget {
  final AppConfig appConfig;
  final OfflineRepository repository;
  final Function(String doctype) onDoctypeSelected;
  final Function(String doctype)? onNewDocument;

  /// When set, used instead of appConfig.doctypes (e.g. from login / getMobileFormDoctypeNames).
  final List<String>? doctypes;

  const DoctypeListScreen({
    super.key,
    required this.appConfig,
    required this.repository,
    required this.onDoctypeSelected,
    this.onNewDocument,
    this.doctypes,
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

  List<String> get _doctypes => widget.doctypes ?? widget.appConfig.doctypes;

  Future<void> _loadDocumentCounts() async {
    setState(() {
      _isLoading = true;
    });

    try {
      for (final doctype in _doctypes) {
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
    return Scaffold(
      appBar: AppBar(title: const Text('Doctypes')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
          ? const Center(child: Text('No doctypes configured'))
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
