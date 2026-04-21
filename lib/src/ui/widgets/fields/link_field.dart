import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import '../../../models/doc_field.dart';
import '../../../models/link_filter_result.dart';
import '../../../services/link_option_service.dart';
import '../../../services/link_field_coordinator.dart';
import '../../../database/entities/link_option_entity.dart';
import 'searchable_select.dart';

/// Widget for Link field type with cached options
class LinkField extends BaseField {
  final LinkOptionService? linkOptionService;
  final LinkFieldCoordinator? linkFieldCoordinator;
  final List<String>? options;
  final Map<String, dynamic>? formData;
  final Map<String, dynamic> parentFormData;
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
      getLinkFilterBuilder;

  const LinkField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.linkOptionService,
    this.linkFieldCoordinator,
    this.options,
    this.formData,
    this.parentFormData = const {},
    this.getLinkFilterBuilder,
  });

  @override
  Widget buildField(BuildContext context) {
    // If options are provided directly, use them
    if (options != null && options!.isNotEmpty) {
      // Validate initialValue is in options list
      final initialValueStr = value?.toString();
      String? validInitialValue;
      if (initialValueStr != null && initialValueStr.isNotEmpty) {
        if (options!.contains(initialValueStr)) {
          validInitialValue = initialValueStr;
        } else {
          // Value not in options - use null
          validInitialValue = null;
        }
      }

      // Auto-select when exactly one option and no valid selection
      if (options!.length == 1 &&
          (validInitialValue == null || validInitialValue.isEmpty)) {
        validInitialValue = options!.first;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          onChanged?.call(options!.first);
        });
      }

      return FormBuilderDropdown<String>(
        key: ValueKey('link_${field.fieldname}_${options!.length}'),
        name: field.fieldname ?? '',
        initialValue: validInitialValue,
        enabled: enabled && !field.readOnly,
        decoration:
            style?.decoration ??
            InputDecoration(
              hintText: field.placeholder ?? 'Select ${field.displayLabel}',
              border: const OutlineInputBorder(),
              filled: field.readOnly,
              fillColor: field.readOnly ? Colors.grey[200] : null,
            ),
        items: options!
            .map(
              (option) => DropdownMenuItem(value: option, child: Text(option)),
            )
            .toList(),
        validator: field.reqd
            ? (value) {
                if (value == null || value.toString().isEmpty) {
                  return '${field.displayLabel} is required';
                }
                return null;
              }
            : null,
        onChanged: (val) => onChanged?.call(val),
      );
    }

    // If field.options contains a DocType name, fetch from service or coordinator
    final effectiveService =
        linkOptionService ?? linkFieldCoordinator?.linkOptionService;
    if (field.options != null &&
        field.options!.isNotEmpty &&
        effectiveService != null) {
      return _LinkFieldDropdown(
        field: field,
        value: value,
        onChanged: onChanged,
        enabled: enabled,
        linkOptionService: effectiveService,
        linkFieldCoordinator: linkFieldCoordinator,
        linkedDoctype: field.options!,
        linkFilters: field.linkFilters,
        formData: formData ?? {},
        parentFormData: parentFormData,
        getLinkFilterBuilder: getLinkFilterBuilder,
        style: style,
      );
    }

    // Fallback to text field
    return FormBuilderTextField(
      key: ValueKey('link_text_${field.fieldname}'),
      name: field.fieldname ?? '',
      initialValue: value?.toString() ?? field.defaultValue ?? '',
      enabled: enabled && !field.readOnly,
      decoration: InputDecoration(
        hintText: field.placeholder ?? 'Enter ${field.displayLabel}',
        border: const OutlineInputBorder(),
        filled: field.readOnly,
        fillColor: field.readOnly ? Colors.grey[200] : null,
        suffixIcon: const Icon(Icons.search),
      ),
      validator: field.reqd
          ? (value) {
              if (value == null || value.toString().isEmpty) {
                return '${field.displayLabel} is required';
              }
              return null;
            }
          : null,
      onChanged: (val) => onChanged?.call(val),
    );
  }
}

/// Dropdown widget that loads options from service or coordinator
class _LinkFieldDropdown extends StatefulWidget {
  final dynamic field;
  final dynamic value;
  final ValueChanged<dynamic>? onChanged;
  final bool enabled;
  final LinkOptionService linkOptionService;
  final LinkFieldCoordinator? linkFieldCoordinator;
  final String linkedDoctype;
  final String? linkFilters;
  final Map<String, dynamic> formData;
  final Map<String, dynamic> parentFormData;
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
      getLinkFilterBuilder;
  final FieldStyle? style;

  const _LinkFieldDropdown({
    required this.field,
    this.value,
    this.onChanged,
    required this.enabled,
    required this.linkOptionService,
    this.linkFieldCoordinator,
    required this.linkedDoctype,
    this.linkFilters,
    required this.formData,
    this.parentFormData = const {},
    this.getLinkFilterBuilder,
    this.style,
  });

  @override
  State<_LinkFieldDropdown> createState() => _LinkFieldDropdownState();
}

class _LinkFieldDropdownState extends State<_LinkFieldDropdown> {
  static const String _kBlankValue = '__blank__';

  List<LinkOptionEntity> _options = [];
  bool _isLoading = true;
  bool _waitingForDependent = false;
  String _dependentFieldName = '';

  @override
  void initState() {
    super.initState();
    if (widget.linkFieldCoordinator != null &&
        widget.linkFieldCoordinator!.useCoordinator) {
      _loadOptionsViaCoordinator();
    } else {
      _loadOptions();
    }
  }

  void _applyOptionsAndAutoSelect(List<LinkOptionEntity> options) {
    if (!mounted) return;
    setState(() {
      _options = options;
      _isLoading = false;
      _waitingForDependent = false;
    });
    if (options.length == 1) {
      final currentVal = widget.value?.toString();
      final hasValidSelection =
          currentVal != null &&
          currentVal.isNotEmpty &&
          options.any(
            (o) => o.name == currentVal || (o.label ?? o.name) == currentVal,
          );
      if (!hasValidSelection) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onChanged?.call(options.first.name);
        });
      }
    }
  }

  void _loadOptionsViaCoordinator() {
    final coordinator = widget.linkFieldCoordinator;
    if (coordinator == null || !coordinator.useCoordinator) {
      _loadOptions();
      return;
    }
    final docField = widget.field is DocField
        ? widget.field as DocField
        : _docFieldFromDynamic(widget.field);
    if (docField == null) {
      _loadOptions();
      return;
    }
    if (!coordinator.canFetchNow(docField, widget.formData) &&
        coordinator.getTier(docField) > 0) {
      final dependentNames = LinkOptionService.getDependentFieldNames(
        widget.linkFilters,
      );
      setState(() {
        _options = [];
        _isLoading = false;
        _waitingForDependent = true;
        _dependentFieldName = dependentNames.isNotEmpty
            ? dependentNames.first
            : '';
      });
      return;
    }
    setState(() => _isLoading = true);
    coordinator.registerField(
      docField,
      widget.formData,
      _applyOptionsAndAutoSelect,
    );
  }

  DocField? _docFieldFromDynamic(dynamic f) {
    if (f == null) return null;
    if (f is DocField) return f;
    return DocField(
      fieldname: f.fieldname?.toString(),
      fieldtype: f.fieldtype ?? 'Link',
      label: f.label?.toString(),
      options: f.options?.toString(),
      linkFilters: f.linkFilters?.toString(),
    );
  }

  Future<void> _loadOptions() async {
    setState(() {
      _isLoading = true;
      _waitingForDependent = false;
    });
    final docField =
        _docFieldFromDynamic(widget.field) ??
        DocField(
          fieldname: widget.field?.fieldname?.toString(),
          fieldtype: 'Link',
          options: widget.linkedDoctype,
          linkFilters: widget.linkFilters,
        );
    final filters = LinkOptionService.resolveFilters(
      field: docField,
      rowData: widget.formData,
      parentFormData: widget.parentFormData,
      hook: widget.getLinkFilterBuilder?.call(
        docField.options ?? '',
        docField.fieldname ?? '',
      ),
    );
    final dependentNames = LinkOptionService.getDependentFieldNames(
      widget.linkFilters,
    );
    if (widget.linkFilters != null &&
        widget.linkFilters!.isNotEmpty &&
        filters == null &&
        dependentNames.isNotEmpty) {
      setState(() {
        _options = [];
        _isLoading = false;
        _waitingForDependent = true;
        _dependentFieldName = dependentNames.first;
      });
      return;
    }
    try {
      final options = await widget.linkOptionService.getLinkOptions(
        widget.linkedDoctype,
        filters: filters,
      );
      _applyOptionsAndAutoSelect(options);
    } catch (e) {
      setState(() {
        _options = [];
        _isLoading = false;
        _waitingForDependent = false;
      });
    }
  }

  @override
  void didUpdateWidget(_LinkFieldDropdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    final useCoordinator =
        widget.linkFieldCoordinator != null &&
        widget.linkFieldCoordinator!.useCoordinator;
    final loadFn = useCoordinator ? _loadOptionsViaCoordinator : _loadOptions;

    if (oldWidget.linkFilters != widget.linkFilters) {
      loadFn();
      return;
    }
    final dependentNames = LinkOptionService.getDependentFieldNames(
      widget.linkFilters,
    );
    if (dependentNames.isEmpty) return;
    for (final key in dependentNames) {
      if (oldWidget.formData[key] != widget.formData[key]) {
        loadFn();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      final loadingValue = widget.value?.toString();
      final hasValue = loadingValue != null && loadingValue.isNotEmpty;
      return FormBuilderDropdown<String>(
        key: ValueKey('${widget.field.fieldname}_loading'),
        name: widget.field.fieldname ?? '',
        initialValue: hasValue ? loadingValue : _kBlankValue,
        enabled: false,
        decoration:
            widget.style?.decoration ??
            const InputDecoration(
              hintText: 'Loading...',
              border: OutlineInputBorder(),
              suffixIcon: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        items: [
          DropdownMenuItem<String>(
            value: _kBlankValue,
            child: Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('Loading...', style: TextStyle(color: Colors.grey[600])),
              ],
            ),
          ),
          if (hasValue)
            DropdownMenuItem<String>(
              value: loadingValue,
              child: Text(loadingValue),
            ),
        ],
      );
    }

    if (_options.isEmpty) {
      final isWaiting = _waitingForDependent && _dependentFieldName.isNotEmpty;
      final hint = isWaiting
          ? 'Select $_dependentFieldName first'
          : 'No options available';
      return FormBuilderDropdown<String>(
        key: ValueKey('${widget.field.fieldname}_empty_$isWaiting'),
        name: widget.field.fieldname ?? '',
        initialValue: _kBlankValue,
        enabled: !isWaiting && (widget.enabled && !widget.field.readOnly),
        decoration:
            widget.style?.decoration ??
            InputDecoration(
              hintText: hint,
              border: const OutlineInputBorder(),
              suffixIcon: isWaiting
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _loadOptions,
                      tooltip: 'Refresh options',
                    ),
            ),
        items: [
          DropdownMenuItem<String>(
            value: _kBlankValue,
            child: Text(hint, style: TextStyle(color: Colors.grey[600])),
          ),
        ],
        onChanged: isWaiting
            ? null
            : (v) => widget.onChanged?.call(v == _kBlankValue ? null : v),
      );
    }

    // Resolve current value from options
    final currentVal = widget.value?.toString();
    final selected = <String>[];
    if (currentVal != null && currentVal.isNotEmpty) {
      // Match by name or label
      final match = _options.any((o) => o.name == currentVal)
          ? currentVal
          : _options
                .where((o) => o.label == currentVal)
                .map((o) => o.name)
                .firstOrNull;
      if (match != null) selected.add(match);
      // Keep unknown values so existing docs still display
      if (match == null) selected.add(currentVal);
    }

    return SearchableSelect(
      options: _options,
      selected: selected,
      multiSelect: false,
      enabled: widget.enabled && !widget.field.readOnly,
      hintText:
          widget.field.placeholder ?? 'Search ${widget.field.displayLabel}...',
      onChanged: (values) {
        widget.onChanged?.call(values.isEmpty ? null : values.first);
      },
    );
  }
}
