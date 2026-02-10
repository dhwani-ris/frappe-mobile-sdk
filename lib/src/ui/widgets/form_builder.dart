import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../models/doc_type_meta.dart';
import '../../models/doc_field.dart';
import '../../constants/field_types.dart';
import '../../services/link_option_service.dart';
import '../../utils/depends_on_evaluator.dart';
import 'fields/field_factory.dart';
import 'fields/base_field.dart';
import 'default_form_style.dart';

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

  /// Upload file to server; when set, Image/Attach fields upload first and store file_url
  final Future<String?> Function(File file)? uploadFile;

  /// Base URL for displaying uploaded file URLs (e.g. for image preview)
  final String? fileUrlBase;

  /// Auth headers for loading private file URLs (e.g. [FrappeClient.requestHeaders])
  final Map<String, String>? imageHeaders;

  /// Fetches a linked document by doctype and name (for fetch_from).
  /// Try local repository first, then server. Return null if not found.
  final Future<Map<String, dynamic>?> Function(
    String linkedDoctype,
    String docName,
  )?
  fetchLinkedDocument;

  /// Resolves child doctype meta for Table fields. Required for child table support.
  final Future<DocTypeMeta> Function(String doctype)? getMeta;

  /// Called once with the form's submit handler so the parent (e.g. FormScreen) can trigger save from AppBar.
  final void Function(void Function() submit)? registerSubmit;

  const FrappeFormBuilder({
    super.key,
    required this.meta,
    this.initialData,
    this.onSubmit,
    this.readOnly = false,
    this.linkOptionService,
    this.customFieldFactory,
    this.style,
    this.uploadFile,
    this.fileUrlBase,
    this.imageHeaders,
    this.fetchLinkedDocument,
    this.getMeta,
    this.registerSubmit,
  });

  @override
  State<FrappeFormBuilder> createState() => _FrappeFormBuilderState();
}

/// Form structure for building tabs/sections
class _FormTab {
  final DocField tabField;
  final List<_FormSection> sections = [];

  _FormTab(this.tabField);
}

class _FormSection {
  final DocField sectionField;
  final List<_FormColumn> columns = [];

  _FormSection(this.sectionField);
}

class _FormColumn {
  final List<DocField> fields = [];
}

class _FrappeFormBuilderState extends State<FrappeFormBuilder>
    with SingleTickerProviderStateMixin {
  late GlobalKey<FormBuilderState> _formKey;
  late final FieldFactory _fieldFactory;
  final Map<String, dynamic> _formData = {};
  late TabController _tabController;
  final List<_FormTab> _tabs = [];

  @override
  void initState() {
    super.initState();
    _formKey = GlobalKey<FormBuilderState>();
    _fieldFactory =
        widget.customFieldFactory ??
        FieldFactory(linkOptionService: widget.linkOptionService);

    _formData.addAll(widget.initialData ?? {});

    for (final field in widget.meta.fields) {
      if (field.fieldname != null &&
          !field.hidden &&
          !_formData.containsKey(field.fieldname)) {
        _formData[field.fieldname!] ??= field.defaultValue;
      }
    }

    _buildFormStructure();
    _tabController = TabController(
      length: _tabs.isEmpty ? 1 : _tabs.length,
      vsync: this,
    );
  }

  void _buildFormStructure() {
    _tabs.clear();
    _FormTab? currentTab;
    _FormSection? currentSection;
    _FormColumn? currentColumn;

    for (final field in widget.meta.fields) {
      if (field.hidden) continue;

      switch (field.fieldtype) {
        case FieldTypes.tabBreak:
          if (currentColumn != null) {
            currentSection ??= _FormSection(
              DocField(fieldtype: 'Section Break', label: ''),
            );
            currentSection.columns.add(currentColumn);
            currentColumn = null;
          }
          if (currentSection != null && currentTab != null) {
            currentTab.sections.add(currentSection);
            currentSection = null;
          }
          if (currentTab != null) {
            _tabs.add(currentTab);
          }
          currentTab = _FormTab(field);
          currentSection = null;
          currentColumn = null;
          break;

        case FieldTypes.sectionBreak:
          if (currentColumn != null) {
            currentSection ??= _FormSection(
              DocField(fieldtype: 'Section Break', label: ''),
            );
            currentSection.columns.add(currentColumn);
            currentColumn = null;
          }
          if (currentSection != null && currentTab != null) {
            currentTab.sections.add(currentSection);
          }
          currentSection = _FormSection(field);
          currentColumn = null;
          break;

        case FieldTypes.columnBreak:
          if (currentColumn != null) {
            currentSection ??= _FormSection(
              DocField(fieldtype: 'Section Break', label: ''),
            );
            currentSection.columns.add(currentColumn);
          }
          currentColumn = _FormColumn();
          break;

        default:
          currentColumn ??= _FormColumn();
          currentSection ??= _FormSection(
            DocField(fieldtype: 'Section Break', label: ''),
          );
          currentTab ??= _FormTab(
            DocField(fieldtype: 'Tab Break', label: 'Details'),
          );
          currentColumn.fields.add(field);
          break;
      }
    }

    // Add remaining structure
    if (currentColumn != null) {
      currentSection ??= _FormSection(
        DocField(fieldtype: 'Section Break', label: ''),
      );
      currentSection.columns.add(currentColumn);
    }
    if (currentSection != null && currentTab != null) {
      currentTab.sections.add(currentSection);
    }
    if (currentTab != null) {
      _tabs.add(currentTab);
    }
  }

  bool _shouldShowField(DocField field) {
    if (field.dependsOn == null || field.dependsOn!.isEmpty) {
      return true;
    }
    return DependsOnEvaluator.evaluate(field.dependsOn, _formData);
  }

  bool _isFieldRequired(DocField field) {
    if (field.reqd) return true;
    if (field.mandatoryDependsOn == null || field.mandatoryDependsOn!.isEmpty) {
      return false;
    }
    return DependsOnEvaluator.evaluate(field.mandatoryDependsOn, _formData);
  }

  bool _isFieldReadOnly(DocField field) {
    if (field.readOnly) return true;
    if (field.readOnlyDependsOn == null || field.readOnlyDependsOn!.isEmpty) {
      return false;
    }
    return DependsOnEvaluator.evaluate(field.readOnlyDependsOn, _formData);
  }

  /// Handles fetch_from: when a Link field changes, fetch the linked document
  /// and patch target fields (format: "link_field_name.source_field_name").
  Future<void> _handleFetchFrom(String changedFieldName, dynamic value) async {
    if (widget.fetchLinkedDocument == null) return;

    final fieldsToUpdate = <DocField>[];
    for (final f in widget.meta.fields) {
      if (f.fetchFrom == null || f.fetchFrom!.isEmpty) continue;
      final parts = f.fetchFrom!.split('.');
      if (parts.length != 2) continue;
      final linkField = parts[0].trim();
      if (linkField == changedFieldName) {
        fieldsToUpdate.add(f);
      }
    }
    if (fieldsToUpdate.isEmpty) return;

    DocField? linkFieldMeta;
    for (final f in widget.meta.fields) {
      if (f.fieldname == changedFieldName) {
        linkFieldMeta = f;
        break;
      }
    }
    if (linkFieldMeta?.options == null) return;

    final linkedDoctype = linkFieldMeta!.options!;
    final linkedDocName = value.toString().trim();

    try {
      final linkedData = await widget.fetchLinkedDocument!(
        linkedDoctype,
        linkedDocName,
      );
      if (linkedData == null || !mounted) return;

      final updates = <String, dynamic>{};
      for (final targetField in fieldsToUpdate) {
        final parts = targetField.fetchFrom!.split('.');
        final sourceFieldName = parts[1].trim();
        if (linkedData.containsKey(sourceFieldName)) {
          final val = linkedData[sourceFieldName];
          if (targetField.fieldname != null) {
            updates[targetField.fieldname!] = val?.toString();
          }
        }
      }
      if (updates.isEmpty) return;

      setState(() {
        _formData.addAll(updates);
      });
      _formKey.currentState?.patchValue(updates);
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('FetchFrom error: $e');
    }
  }

  Widget _buildFieldWidget(DocField field) {
    if (!_shouldShowField(field)) {
      return const SizedBox.shrink();
    }

    final formStyle = widget.style ?? DefaultFormStyle.standard;
    final fieldStyle = FieldStyle(
      labelStyle: formStyle.labelStyle,
      descriptionStyle: formStyle.descriptionStyle,
      decoration: formStyle.fieldDecoration?.call(field),
    );

    final effectiveReqd = _isFieldRequired(field);
    final effectiveReadOnly = _isFieldReadOnly(field) || widget.readOnly;

    final fieldWithEffectiveProps = DocField(
      fieldname: field.fieldname,
      fieldtype: field.fieldtype,
      label: field.label,
      reqd: effectiveReqd,
      readOnly: effectiveReadOnly,
      hidden: field.hidden,
      options: field.options,
      dependsOn: field.dependsOn,
      mandatoryDependsOn: field.mandatoryDependsOn,
      readOnlyDependsOn: field.readOnlyDependsOn,
      linkFilters: field.linkFilters,
      fetchFrom: field.fetchFrom,
      section: field.section,
      defaultValue: field.defaultValue,
      description: field.description,
      placeholder: field.placeholder,
      precision: field.precision,
      length: field.length,
      idx: field.idx,
      inListView: field.inListView,
      allowMultiple: field.allowMultiple,
    );

    final initialValue =
        _formData[field.fieldname] ??
        widget.initialData?[field.fieldname] ??
        field.defaultValue;

    final fieldWidget = _fieldFactory.createField(
      field: fieldWithEffectiveProps,
      value: initialValue,
      uploadFile: widget.uploadFile,
      fileUrlBase: widget.fileUrlBase,
      imageHeaders: widget.imageHeaders,
      getMeta: widget.getMeta,
      childTableFormBuilder: widget.getMeta != null
          ? (childMeta, initialData, onSubmit, {registerSubmit}) =>
                FrappeFormBuilder(
                  meta: childMeta,
                  initialData: initialData,
                  onSubmit: onSubmit,
                  registerSubmit: registerSubmit,
                  getMeta: widget.getMeta,
                  fileUrlBase: widget.fileUrlBase,
                  imageHeaders: widget.imageHeaders,
                  fetchLinkedDocument: widget.fetchLinkedDocument,
                )
          : null,
      onChanged: (value) {
        setState(() {
          final oldValue = _formData[field.fieldname];
          if (value == null) {
            if (field.fieldname != null) {
              _formData.remove(field.fieldname);
            }
          } else {
            if (field.fieldname != null) {
              _formData[field.fieldname!] = value;
            }
          }

          // If value changed, clear dependent link fields that depend on this field
          if (oldValue != value && field.fieldname != null) {
            for (final otherField in widget.meta.fields) {
              if (otherField.fieldtype == 'Link' &&
                  otherField.linkFilters != null &&
                  otherField.linkFilters!.contains(
                    'eval:doc.${field.fieldname}',
                  )) {
                _formData.remove(otherField.fieldname);
              }
            }
          }

          // Fetch-from: when a Link (or source field) changes, fetch linked doc and patch form
          if (oldValue != value &&
              field.fieldname != null &&
              value != null &&
              value.toString().trim().isNotEmpty) {
            _handleFetchFrom(field.fieldname!, value);
          }

          // Trigger rebuild to update dependent fields
          if (oldValue != value) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
          }
        });
      },
      enabled: !effectiveReadOnly,
      formData: Map<String, dynamic>.from(_formData),
      style: fieldStyle,
    );

    if (fieldWidget == null) return const SizedBox.shrink();

    return Padding(
      padding: formStyle.fieldPadding ?? const EdgeInsets.only(bottom: 16.0),
      child: fieldWidget,
    );
  }

  Widget _buildColumn(_FormColumn column) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: column.fields.map((field) => _buildFieldWidget(field)).toList(),
    );
  }

  Widget _buildSection(_FormSection section) {
    final formStyle = widget.style ?? DefaultFormStyle.standard;

    if (section.columns.isEmpty) return const SizedBox.shrink();

    Widget content;
    if (section.columns.length == 1) {
      content = _buildColumn(section.columns.first);
    } else {
      // Responsive layout: Use Row on larger screens, Column on smaller screens
      content = LayoutBuilder(
        builder: (context, constraints) {
          final isWideScreen = constraints.maxWidth > 600;

          if (isWideScreen) {
            // Desktop/Tablet: Side by side columns
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: section.columns.map((col) {
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: _buildColumn(col),
                  ),
                );
              }).toList(),
            );
          } else {
            // Mobile: Stack columns vertically
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: section.columns.map((col) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: _buildColumn(col),
                );
              }).toList(),
            );
          }
        },
      );
    }

    if (section.sectionField.label == null ||
        section.sectionField.label!.isEmpty) {
      return Padding(
        padding: formStyle.sectionPadding ?? const EdgeInsets.all(16.0),
        child: content,
      );
    }

    return Card(
      margin: formStyle.sectionMargin ?? const EdgeInsets.only(bottom: 16.0),
      child: Padding(
        padding: formStyle.sectionPadding ?? const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              section.sectionField.displayLabel,
              style:
                  formStyle.sectionTitleStyle ??
                  Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            content,
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent(_FormTab tab) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: tab.sections
            .map((section) => _buildSection(section))
            .toList(),
      ),
    );
  }

  @override
  void didUpdateWidget(FrappeFormBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialData != widget.initialData ||
        oldWidget.meta != widget.meta) {
      _formKey = GlobalKey<FormBuilderState>();
      _formData.clear();
      if (widget.initialData != null) {
        _formData.addAll(widget.initialData!);
      }
      _buildFormStructure();
      _tabController.dispose();
      _tabController = TabController(
        length: _tabs.isEmpty ? 1 : _tabs.length,
        vsync: this,
      );
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _handleSubmit() {
    if (_formKey.currentState?.saveAndValidate() ?? false) {
      // Save all form fields first to ensure FormBuilder captures all values
      _formKey.currentState!.save();

      // Get all form values from FormBuilder (includes all fields)
      final formValues = Map<String, dynamic>.from(
        _formKey.currentState!.value,
      );

      // Merge with _formData (fields that were changed via onChanged)
      formValues.addAll(_formData);

      // Build complete form data with ALL fields from metadata
      // This ensures we save complete data, not just changed fields
      final completeFormData = <String, dynamic>{};

      // First, initialize all fields from metadata with their default/initial values
      for (final field in widget.meta.fields) {
        if (field.fieldname != null && !field.hidden) {
          // Priority: formValues > initialData > defaultValue > empty value
          completeFormData[field.fieldname!] =
              formValues[field.fieldname] ??
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
    if (_tabs.isEmpty) {
      return const Center(child: Text('No fields to display'));
    }
    widget.registerSubmit?.call(_handleSubmit);

    return FormBuilder(
      key: _formKey,
      child: Column(
        children: [
          if (_tabs.length > 1)
            TabBar(
              controller: _tabController,
              tabs: _tabs
                  .map((tab) => Tab(text: tab.tabField.displayLabel))
                  .toList(),
            ),
          Expanded(
            child: _tabs.length > 1
                ? TabBarView(
                    controller: _tabController,
                    children: _tabs
                        .map((tab) => _buildTabContent(tab))
                        .toList(),
                  )
                : _buildTabContent(_tabs.first),
          ),
        ],
      ),
    );
  }
}
