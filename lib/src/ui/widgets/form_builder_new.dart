// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

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

/// Main form builder widget that renders Frappe forms based on metadata
/// Supports tabs, sections, columns, and conditional field visibility
class FrappeFormBuilderNew extends StatefulWidget {
  final DocTypeMeta meta;
  final Map<String, dynamic>? initialData;
  final Function(Map<String, dynamic>)? onSubmit;
  final bool readOnly;
  final LinkOptionService? linkOptionService;
  final FieldFactory? customFieldFactory;
  final FrappeFormStyle? style;

  const FrappeFormBuilderNew({
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
  State<FrappeFormBuilderNew> createState() => _FrappeFormBuilderNewState();
}

class _FrappeFormBuilderNewState extends State<FrappeFormBuilderNew> with SingleTickerProviderStateMixin {
  late GlobalKey<FormBuilderState> _formKey;
  late final FieldFactory _fieldFactory;
  final Map<String, dynamic> _formData = {};
  late TabController _tabController;
  List<_FormTab> _tabs = [];
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _formKey = GlobalKey<FormBuilderState>();
    _fieldFactory = widget.customFieldFactory ?? 
        FieldFactory(linkOptionService: widget.linkOptionService);
    
    if (widget.initialData != null) {
      _formData.addAll(widget.initialData!);
    }
    
    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !field.hidden && !_formData.containsKey(field.fieldname)) {
        if (field.defaultValue != null) {
          _formData[field.fieldname!] = field.defaultValue;
        }
      }
    }
    
    _buildFormStructure();
    _tabController = TabController(length: _tabs.length, vsync: this);
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
          if (currentSection != null && currentColumn != null) {
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
            if (currentSection == null) {
              currentSection = _FormSection(DocField(
                fieldtype: 'Section Break',
                label: '',
              ));
            }
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
            if (currentSection == null) {
              currentSection = _FormSection(DocField(
                fieldtype: 'Section Break',
                label: '',
              ));
            }
            currentSection.columns.add(currentColumn);
          }
          currentColumn = _FormColumn();
          break;

        default:
          if (currentColumn == null) {
            currentColumn = _FormColumn();
          }
          if (currentSection == null && currentTab != null) {
            currentSection = _FormSection(DocField(
              fieldtype: 'Section Break',
              label: '',
            ));
          }
          if (currentTab == null) {
            currentTab = _FormTab(DocField(
              fieldtype: 'Tab Break',
              label: 'Details',
            ));
          }
          currentColumn.fields.add(field);
          break;
      }
    }

    // Add remaining structure
    if (currentColumn != null) {
      if (currentSection == null) {
        currentSection = _FormSection(DocField(
          fieldtype: 'Section Break',
          label: '',
        ));
      }
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
      section: field.section,
      defaultValue: field.defaultValue,
      description: field.description,
      placeholder: field.placeholder,
      precision: field.precision,
      length: field.length,
      idx: field.idx,
      inListView: field.inListView,
    );

    final initialValue = widget.initialData?[field.fieldname] ?? field.defaultValue;

    final fieldWidget = _fieldFactory.createField(
      field: fieldWithEffectiveProps,
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
      enabled: !effectiveReadOnly,
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
      content = Row(
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
    }

    if (section.sectionField.label == null || section.sectionField.label!.isEmpty) {
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
              style: formStyle.sectionTitleStyle ?? 
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
        children: tab.sections.map((section) => _buildSection(section)).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) {
      return const Center(child: Text('No fields to display'));
    }

    return FormBuilder(
      key: _formKey,
      child: Column(
        children: [
          if (_tabs.length > 1)
            TabBar(
              controller: _tabController,
              tabs: _tabs.map((tab) => Tab(text: tab.tabField.displayLabel)).toList(),
              onTap: (index) {
                setState(() {
                  _currentTabIndex = index;
                });
              },
            ),
          Expanded(
            child: _tabs.length > 1
                ? TabBarView(
                    controller: _tabController,
                    children: _tabs.map((tab) => _buildTabContent(tab)).toList(),
                  )
                : _buildTabContent(_tabs.first),
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

  void _handleSubmit() {
    if (_formKey.currentState?.saveAndValidate() ?? false) {
      _formKey.currentState!.save();
      final formValues = Map<String, dynamic>.from(_formKey.currentState!.value);
      formValues.addAll(_formData);

      final completeFormData = <String, dynamic>{};
      for (final field in widget.meta.fields) {
        if (field.fieldname != null && !field.hidden) {
          completeFormData[field.fieldname!] = formValues[field.fieldname] ?? 
              widget.initialData?[field.fieldname] ?? 
              field.defaultValue ?? 
              (field.fieldtype == 'Check' ? 0 : '');
        }
      }
      completeFormData.addAll(formValues);
      widget.onSubmit?.call(completeFormData);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }
}
