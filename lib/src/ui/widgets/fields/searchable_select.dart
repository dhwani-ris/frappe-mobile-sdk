import 'package:flutter/material.dart';
import '../../../database/entities/link_option_entity.dart';

/// Reusable searchable select widget for Frappe Link options.
///
/// Two modes controlled by [multiSelect]:
/// - **Single** (`false`): type-ahead search -> pick one value -> collapses.
/// - **Multi** (`true`): chips for selected values + search -> pick many.
///
/// Call site only needs to supply [options] (pre-loaded) and handle changes.
/// Option loading is the caller's responsibility.
class SearchableSelect extends StatefulWidget {
  const SearchableSelect({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.multiSelect = false,
    this.enabled = true,
    this.loading = false,
    this.hintText,
  });

  /// All available options (already loaded).
  final List<LinkOptionEntity> options;

  /// Currently selected value(s).
  final List<String> selected;

  /// Called when selection changes — single list for both modes.
  final ValueChanged<List<String>> onChanged;

  final bool multiSelect;
  final bool enabled;
  final bool loading;
  final String? hintText;

  @override
  State<SearchableSelect> createState() => _SearchableSelectState();
}

class _SearchableSelectState extends State<SearchableSelect> {
  String _search = '';
  bool _showSuggestions = false;
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted) return;
    setState(() => _showSuggestions = _focusNode.hasFocus);
  }

  String _labelFor(String name) =>
      widget.options
          .where((o) => o.name == name)
          .map((o) => o.label ?? o.name)
          .firstOrNull ??
      name;

  List<LinkOptionEntity> get _filtered {
    return widget.options
        .where((o) => !widget.selected.contains(o.name))
        .where(
          (o) =>
              _search.isEmpty ||
              (o.label ?? o.name).toLowerCase().contains(_search.toLowerCase()),
        )
        .take(8)
        .toList();
  }

  void _pick(String name) {
    if (widget.multiSelect) {
      if (widget.selected.contains(name)) return;
      widget.onChanged([...widget.selected, name]);
    } else {
      widget.onChanged([name]);
    }
    _controller.clear();
    setState(() {
      _search = '';
      _showSuggestions = false;
    });
    _focusNode.unfocus();
  }

  void _remove(String name) {
    widget.onChanged(widget.selected.where((v) => v != name).toList());
  }

  void _clear() {
    widget.onChanged([]);
    _controller.clear();
    setState(() => _search = '');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final selected = widget.selected;
    final filtered = _filtered;
    final hasValue = selected.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Multi-select chips
        if (widget.multiSelect && hasValue)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: selected.map((val) {
                return Chip(
                  label: Text(
                    _labelFor(val),
                    style: const TextStyle(fontSize: 13),
                  ),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: widget.enabled ? () => _remove(val) : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                );
              }).toList(),
            ),
          ),

        // Single-select current value
        if (!widget.multiSelect && hasValue && !_showSuggestions)
          GestureDetector(
            onTap: widget.enabled
                ? () {
                    _focusNode.requestFocus();
                    setState(() => _showSuggestions = true);
                  }
                : null,
            child: InputDecorator(
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: const OutlineInputBorder(),
                suffixIcon: widget.enabled
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _clear,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      )
                    : null,
              ),
              child: Text(
                _labelFor(selected.first),
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),

        // Search input
        if (widget.enabled &&
            (widget.multiSelect || !hasValue || _showSuggestions))
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            decoration: InputDecoration(
              hintText:
                  widget.hintText ??
                  (widget.multiSelect
                      ? (hasValue ? 'Add more...' : 'Search & select...')
                      : 'Search...'),
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: const OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 14),
            onChanged: (text) => setState(() => _search = text),
          ),

        // Suggestion list
        if (_showSuggestions && filtered.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final opt = filtered[index];
                return InkWell(
                  onTap: () => _pick(opt.name),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Text(
                      opt.label ?? opt.name,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                );
              },
            ),
          ),

        // Empty state
        if (_showSuggestions && _search.isNotEmpty && filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'No matching options',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
          ),
      ],
    );
  }
}
