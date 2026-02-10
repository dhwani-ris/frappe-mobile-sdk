import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import '../../../services/link_option_service.dart';
import '../../../database/entities/link_option_entity.dart';

/// Widget for Link field type with cached options
class LinkField extends BaseField {
  final LinkOptionService? linkOptionService;
  final List<String>? options;
  final Map<String, dynamic>? formData;

  const LinkField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.linkOptionService,
    this.options,
    this.formData,
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

    // If field.options contains a DocType name, fetch from service
    if (field.options != null &&
        field.options!.isNotEmpty &&
        linkOptionService != null) {
      return _LinkFieldDropdown(
        field: field,
        value: value,
        onChanged: onChanged,
        enabled: enabled,
        linkOptionService: linkOptionService!,
        linkedDoctype: field.options!,
        linkFilters: field.linkFilters,
        formData: formData ?? {},
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

/// Dropdown widget that loads options from service
class _LinkFieldDropdown extends StatefulWidget {
  final dynamic field;
  final dynamic value;
  final ValueChanged<dynamic>? onChanged;
  final bool enabled;
  final LinkOptionService linkOptionService;
  final String linkedDoctype;
  final String? linkFilters;
  final Map<String, dynamic> formData;
  final FieldStyle? style;

  const _LinkFieldDropdown({
    required this.field,
    this.value,
    this.onChanged,
    required this.enabled,
    required this.linkOptionService,
    required this.linkedDoctype,
    this.linkFilters,
    required this.formData,
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
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    setState(() {
      _isLoading = true;
      _waitingForDependent = false;
    });
    final filters = LinkOptionService.parseLinkFilters(
      widget.linkFilters,
      widget.formData,
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
      setState(() {
        _options = options;
        _isLoading = false;
        _waitingForDependent = false;
      });
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
    // Reload options only if linkFilters changed or a *dependent* form field changed
    if (oldWidget.linkFilters != widget.linkFilters) {
      _loadOptions();
      return;
    }
    final dependentNames = LinkOptionService.getDependentFieldNames(
      widget.linkFilters,
    );
    if (dependentNames.isEmpty) return;
    for (final key in dependentNames) {
      if (oldWidget.formData[key] != widget.formData[key]) {
        _loadOptions();
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

    // Resolve initial value: match from options by name or label; if not in list, keep value so it still displays
    final initialValueStr = widget.value?.toString();
    String? validInitialValue;
    if (initialValueStr != null && initialValueStr.isNotEmpty) {
      if (_options.isNotEmpty) {
        try {
          final matchingOption = _options.firstWhere(
            (opt) => opt.name == initialValueStr,
          );
          validInitialValue = matchingOption.name;
        } catch (_) {
          try {
            final matchingOption = _options.firstWhere(
              (opt) => opt.label == initialValueStr,
            );
            validInitialValue = matchingOption.name;
          } catch (_) {
            validInitialValue = null;
          }
        }
      } else {
        validInitialValue = initialValueStr;
      }
    }

    final placeholder =
        widget.field.placeholder ?? 'Select ${widget.field.displayLabel}';
    final allItems = <DropdownMenuItem<String>>[
      DropdownMenuItem<String>(
        value: _kBlankValue,
        child: Text(placeholder, style: TextStyle(color: Colors.grey[600])),
      ),
      // If current value is not in options (e.g. existing doc), add it so selected value shows
      if (validInitialValue != null &&
          validInitialValue != _kBlankValue &&
          !_options.any((opt) => opt.name == validInitialValue))
        DropdownMenuItem<String>(
          value: validInitialValue,
          child: Text(validInitialValue),
        ),
      ..._options.map(
        (option) => DropdownMenuItem<String>(
          value: option.name,
          child: Text(option.label ?? option.name),
        ),
      ),
    ];
    final initialVal = validInitialValue ?? _kBlankValue;

    return FormBuilderDropdown<String>(
      key: ValueKey(
        'link_dropdown_${widget.field.fieldname}_${_options.length}',
      ),
      name: widget.field.fieldname ?? '',
      initialValue: initialVal,
      enabled: widget.enabled && !widget.field.readOnly,
      decoration:
          widget.style?.decoration ??
          InputDecoration(
            hintText: placeholder,
            border: const OutlineInputBorder(),
            filled: widget.field.readOnly,
            fillColor: widget.field.readOnly ? Colors.grey[200] : null,
            suffixIcon: IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadOptions,
              tooltip: 'Refresh options',
            ),
          ),
      items: allItems,
      validator: widget.field.reqd
          ? (value) {
              if (value == null ||
                  value.toString().isEmpty ||
                  value == _kBlankValue) {
                return '${widget.field.displayLabel} is required';
              }
              return null;
            }
          : null,
      onChanged: (val) =>
          widget.onChanged?.call(val == _kBlankValue ? null : val),
    );
  }
}
