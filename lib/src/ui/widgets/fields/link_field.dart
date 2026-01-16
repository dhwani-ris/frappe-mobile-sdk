import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'base_field.dart';
import '../../../services/link_option_service.dart';
import '../../../database/entities/link_option_entity.dart';

/// Widget for Link field type with cached options
class LinkField extends BaseField {
  final LinkOptionService? linkOptionService;
  final List<String>? options;

  const LinkField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
    this.linkOptionService,
    this.options,
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
        key: ValueKey('${field.fieldname}_${validInitialValue ?? ''}_${options!.length}'),
        name: field.fieldname ?? '',
        initialValue: validInitialValue,
        enabled: enabled && !field.readOnly,
        decoration: style?.decoration ?? InputDecoration(
          hintText: field.placeholder ?? 'Select ${field.displayLabel}',
          border: const OutlineInputBorder(),
          filled: field.readOnly,
          fillColor: field.readOnly ? Colors.grey[200] : null,
        ),
        items: options!
            .map((option) => DropdownMenuItem(
                  value: option,
                  child: Text(option),
                ))
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
    if (field.options != null && field.options!.isNotEmpty && linkOptionService != null) {
      return _LinkFieldDropdown(
        field: field,
        value: value,
        onChanged: onChanged,
        enabled: enabled,
        linkOptionService: linkOptionService!,
        linkedDoctype: field.options!,
        style: style,
      );
    }

    // Fallback to text field
    return FormBuilderTextField(
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
  final FieldStyle? style;

  const _LinkFieldDropdown({
    required this.field,
    this.value,
    this.onChanged,
    required this.enabled,
    required this.linkOptionService,
    required this.linkedDoctype,
    this.style,
  });

  @override
  State<_LinkFieldDropdown> createState() => _LinkFieldDropdownState();
}

class _LinkFieldDropdownState extends State<_LinkFieldDropdown> {
  List<LinkOptionEntity> _options = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    setState(() => _isLoading = true);
    try {
      final options = await widget.linkOptionService.getLinkOptions(widget.linkedDoctype);
      setState(() {
        _options = options;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return FormBuilderDropdown<String>(
        key: ValueKey('${widget.field.fieldname}_loading'),
        name: widget.field.fieldname ?? '',
        enabled: false,
        decoration: widget.style?.decoration ?? InputDecoration(
          hintText: 'Loading options...',
          border: const OutlineInputBorder(),
          suffixIcon: const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        items: const [],
      );
    }

    if (_options.isEmpty) {
      return FormBuilderTextField(
        key: ValueKey('${widget.field.fieldname}_empty_${widget.value?.toString() ?? ''}'),
        name: widget.field.fieldname ?? '',
        initialValue: widget.value?.toString() ?? '',
        enabled: widget.enabled && !widget.field.readOnly,
        decoration: widget.style?.decoration ?? InputDecoration(
          hintText: 'No options available. Tap refresh to load.',
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadOptions,
            tooltip: 'Refresh options',
          ),
        ),
      );
    }

    // Validate initialValue is in options list
    final initialValueStr = widget.value?.toString();
    String? validInitialValue;
    if (initialValueStr != null && initialValueStr.isNotEmpty && _options.isNotEmpty) {
      // Try to find matching option by name first
      try {
        final matchingOption = _options.firstWhere(
          (opt) => opt.name == initialValueStr,
        );
        validInitialValue = matchingOption.name;
      } catch (e) {
        // Not found by name, try by label
        try {
          final matchingOption = _options.firstWhere(
            (opt) => opt.label == initialValueStr,
          );
          validInitialValue = matchingOption.name;
        } catch (e2) {
          // Not found - use null (will show placeholder)
          validInitialValue = null;
        }
      }
    }

    return FormBuilderDropdown<String>(
      key: ValueKey('${widget.field.fieldname}_${validInitialValue ?? ''}_${_options.length}'),
      name: widget.field.fieldname ?? '',
      initialValue: validInitialValue,
      enabled: widget.enabled && !widget.field.readOnly,
      decoration: widget.style?.decoration ?? InputDecoration(
        hintText: widget.field.placeholder ?? 'Select ${widget.field.displayLabel}',
        border: const OutlineInputBorder(),
        filled: widget.field.readOnly,
        fillColor: widget.field.readOnly ? Colors.grey[200] : null,
        suffixIcon: IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadOptions,
          tooltip: 'Refresh options',
        ),
      ),
      items: _options
          .map((option) => DropdownMenuItem(
                value: option.name,
                child: Text(option.label ?? option.name),
              ))
          .toList(),
      validator: widget.field.reqd
          ? (value) {
              if (value == null || value.toString().isEmpty) {
                return '${widget.field.displayLabel} is required';
              }
              return null;
            }
          : null,
      onChanged: (val) => widget.onChanged?.call(val),
    );
  }
}

