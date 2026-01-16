import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../models/doc_type_meta.dart';
import '../../models/doc_field.dart';
import '../../constants/field_types.dart';
import '../../services/link_option_service.dart';
import 'fields/field_factory.dart';
import 'fields/base_field.dart';

/// Customization options for form styling
class FrappeFormStyle {
  /// Custom InputDecoration builder for text fields
  final InputDecoration Function(DocField field)? fieldDecoration;
  
  /// Custom label text style
  final TextStyle? labelStyle;
  
  /// Custom description text style
  final TextStyle? descriptionStyle;
  
  /// Custom section title style
  final TextStyle? sectionTitleStyle;
  
  /// Custom section card margin
  final EdgeInsets? sectionMargin;
  
  /// Custom section card padding
  final EdgeInsets? sectionPadding;
  
  /// Custom field spacing
  final EdgeInsets? fieldPadding;

  const FrappeFormStyle({
    this.fieldDecoration,
    this.labelStyle,
    this.descriptionStyle,
    this.sectionTitleStyle,
    this.sectionMargin,
    this.sectionPadding,
    this.fieldPadding,
  });
}

/// Main form builder widget that renders Frappe forms based on metadata
class FrappeFormBuilder extends StatefulWidget {
  final DocTypeMeta meta;
  final Map<String, dynamic>? initialData;
  final Function(Map<String, dynamic>)? onSubmit;
  final bool readOnly;
  final LinkOptionService? linkOptionService;
  
  /// Custom field factory (if null, uses default FieldFactory)
  final FieldFactory? customFieldFactory;
  
  /// Custom styling options
  final FrappeFormStyle? style;

  const FrappeFormBuilder({
    super.key,
    required this.meta,
    this.initialData,
    this.onSubmit,
    this.readOnly = false,
    this.linkOptionService,
    this.customFieldFactory,
    this.style,
  });

  @override
  State<FrappeFormBuilder> createState() => _FrappeFormBuilderState();
}

class _FrappeFormBuilderState extends State<FrappeFormBuilder> {
  late GlobalKey<FormBuilderState> _formKey;
  late final FieldFactory _fieldFactory;
  final Map<String, dynamic> _formData = {};

  @override
  void initState() {
    super.initState();
    _formKey = GlobalKey<FormBuilderState>();
    // Use custom factory if provided, otherwise create default
    _fieldFactory = widget.customFieldFactory ?? 
        FieldFactory(linkOptionService: widget.linkOptionService);
    // Initialize form data with initialData if available
    // This ensures all fields from existing document are included
    if (widget.initialData != null) {
      _formData.addAll(widget.initialData!);
    }
    // Also initialize with default values for fields that don't have initialData
    // This ensures ALL fields are tracked, not just ones with values
    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !field.hidden && !_formData.containsKey(field.fieldname)) {
        if (field.defaultValue != null) {
          _formData[field.fieldname!] = field.defaultValue;
        }
      }
    }
  }

  @override
  void didUpdateWidget(FrappeFormBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset form key when initialData changes to force form rebuild with new data
    if (oldWidget.initialData != widget.initialData ||
        oldWidget.meta != widget.meta) {
      _formKey = GlobalKey<FormBuilderState>();
      // Update form data with new initialData
      _formData.clear();
      if (widget.initialData != null) {
        _formData.addAll(widget.initialData!);
      }
    }
  }
  
  @override
  void dispose() {
    // Clean up form key to prevent memory leaks
    _formKey = GlobalKey<FormBuilderState>();
    super.dispose();
  }

  List<Widget> _buildForm(BuildContext context) {
    final formWidgets = <Widget>[];
    List<Widget> currentSectionChildren = [];
    DocField? currentSection;

    for (final field in widget.meta.fields) {
      if (field.hidden) continue;

      switch (field.fieldtype) {
        case FieldTypes.sectionBreak:
          // Save previous section
          if (currentSection != null && currentSectionChildren.isNotEmpty) {
            formWidgets.add(
              _buildSection(context, currentSection, currentSectionChildren),
            );
            currentSectionChildren = [];
          }
          currentSection = field;
          break;

        case FieldTypes.columnBreak:
          // For now, column breaks are treated as regular fields
          // TODO: Implement proper column layout
          break;

        case FieldTypes.tabBreak:
          // For now, tabs are treated as sections
          if (currentSection != null && currentSectionChildren.isNotEmpty) {
            formWidgets.add(
              _buildSection(context, currentSection, currentSectionChildren),
            );
            currentSectionChildren = [];
          }
          currentSection = field;
          break;

        default:
          // Regular field
          final fieldStyle = widget.style != null
              ? FieldStyle(
                  labelStyle: widget.style!.labelStyle,
                  descriptionStyle: widget.style!.descriptionStyle,
                  decoration: widget.style!.fieldDecoration?.call(field),
                )
              : null;
          
          // Get initial value: initialData > defaultValue > empty
          final initialValue = widget.initialData?[field.fieldname] ?? field.defaultValue;
          
          final fieldWidget = _fieldFactory.createField(
            field: field,
            value: initialValue,
            onChanged: (value) {
              setState(() {
                if (value == null) {
                  if (field.fieldname != null) {
                    _formData.remove(field.fieldname);
                  }
                } else {
                  if (field.fieldname != null) {
                    _formData[field.fieldname!] = value;
                  }
                }
              });
            },
            enabled: !widget.readOnly,
            style: fieldStyle,
          );
          
          // Initialize _formData with initial values for all fields
          // This ensures all fields are included in form submission
          if (field.fieldname != null && !field.hidden && !_formData.containsKey(field.fieldname)) {
            if (initialValue != null) {
              _formData[field.fieldname!] = initialValue;
            }
          }

          if (fieldWidget != null) {
            currentSectionChildren.add(
              Padding(
                padding: widget.style?.fieldPadding ?? 
                    const EdgeInsets.only(bottom: 16.0),
                child: fieldWidget,
              ),
            );
          }
          break;
      }
    }

    // Add remaining fields
    if (currentSectionChildren.isNotEmpty) {
      if (currentSection != null) {
        formWidgets.add(
          _buildSection(context, currentSection, currentSectionChildren),
        );
      } else {
        formWidgets.add(
          Column(children: currentSectionChildren),
        );
      }
    }
    
    return formWidgets;
  }

  Widget _buildSection(BuildContext context, DocField sectionField, List<Widget> children) {
    final style = widget.style;
    return Card(
      margin: style?.sectionMargin ?? const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: style?.sectionPadding ?? const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sectionField.displayLabel,
              style: style?.sectionTitleStyle ?? 
                  Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  void _handleSubmit() {
    if (_formKey.currentState?.saveAndValidate() ?? false) {
      // Save all form fields first to ensure FormBuilder captures all values
      _formKey.currentState!.save();
      
      // Get all form values from FormBuilder (includes all fields)
      final formValues = Map<String, dynamic>.from(_formKey.currentState!.value);
      
      // Merge with _formData (fields that were changed via onChanged)
      formValues.addAll(_formData);
      
      // Build complete form data with ALL fields from metadata
      // This ensures we save complete data, not just changed fields
      final completeFormData = <String, dynamic>{};
      
      // First, initialize all fields from metadata with their default/initial values
      for (final field in widget.meta.fields) {
        if (field.fieldname != null && !field.hidden) {
          // Priority: formValues > initialData > defaultValue > empty value
          completeFormData[field.fieldname!] = formValues[field.fieldname] ?? 
              widget.initialData?[field.fieldname] ?? 
              field.defaultValue ?? 
              (field.fieldtype == 'Check' ? 0 : '');
        }
      }
      
      // Then override with any form values (user input takes precedence)
      completeFormData.addAll(formValues);
      
      widget.onSubmit?.call(completeFormData);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild form widgets every time (so initialData changes are reflected)
    final formWidgets = _buildForm(context);

    return FormBuilder(
      key: _formKey,
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: formWidgets,
              ),
            ),
          ),
          if (!widget.readOnly && widget.onSubmit != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
                onPressed: _handleSubmit,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text('Submit'),
              ),
            ),
        ],
      ),
    );
  }
}
