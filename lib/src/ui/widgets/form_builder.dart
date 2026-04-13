import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../models/doc_type_meta.dart';
import '../../models/doc_field.dart';
import '../../constants/field_types.dart';
import '../../services/link_option_service.dart';
import '../../services/link_field_coordinator.dart';
import '../../utils/depends_on_evaluator.dart';
import 'fields/field_factory.dart';
import 'fields/base_field.dart';
import 'default_form_style.dart';

/// Simple 2-arg callback for Button field. Used by [FrappeFormBuilder] and [renderForm].
typedef ButtonPressedCallback =
    Future<void> Function(DocField field, Map<String, dynamic> formData);

/// Callback when a Button field is pressed. Implement client-script logic (API calls, dialogs).
/// Call [useDefault] to fall back to SDK default (server method from [field.options] when set).
/// Used by [FormScreen] and [navigateToForm].
typedef OnButtonPressedCallback =
    Future<void> Function(
      DocField field,
      Map<String, dynamic> formData,
      Future<void> Function(DocField field, Map<String, dynamic> formData)
      useDefault,
    );

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

  /// Max lines for section titles before ellipsis (default: 3)
  final int? sectionTitleMaxLines;

  /// Max lines for tab titles before ellipsis (default: 2)
  final int? tabTitleMaxLines;

  const FrappeFormStyle({
    this.fieldDecoration,
    this.labelStyle,
    this.descriptionStyle,
    this.sectionTitleStyle,
    this.sectionMargin,
    this.sectionPadding,
    this.fieldPadding,
    this.sectionTitleMaxLines,
    this.tabTitleMaxLines,
  });
}

/// Main form builder widget that renders Frappe forms based on metadata
class FrappeFormBuilder extends StatefulWidget {
  final DocTypeMeta meta;
  final Map<String, dynamic>? initialData;
  final Function(Map<String, dynamic>)? onSubmit;
  final bool readOnly;
  final LinkOptionService? linkOptionService;

  /// When true (default), use LinkFieldCoordinator for sequenced link option loading.
  final bool useLinkFieldCoordinator;

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

  /// If set, field labels, section titles and tab labels are passed through this (e.g. sdk.translations.translate).
  final String Function(String)? translate;

  /// Called when a Button field is pressed. [FormScreen] adapts [OnButtonPressedCallback] to this.
  final ButtonPressedCallback? onButtonPressed;

  /// Called when form data changes (any field value). Use to detect dirty state.
  final void Function(Map<String, dynamic> currentData)? onFormDataChanged;

  /// Called when a field value changes. Returns a map of computed field updates
  /// to patch into the form (e.g. for hidden computed fields).
  final Map<String, dynamic>? Function(
    String fieldName,
    dynamic newValue,
    Map<String, dynamic> formData,
  )?
  onFieldChange;

  const FrappeFormBuilder({
    super.key,
    required this.meta,
    this.initialData,
    this.onSubmit,
    this.readOnly = false,
    this.linkOptionService,
    this.useLinkFieldCoordinator = true,
    this.customFieldFactory,
    this.style,
    this.uploadFile,
    this.fileUrlBase,
    this.imageHeaders,
    this.fetchLinkedDocument,
    this.getMeta,
    this.registerSubmit,
    this.translate,
    this.onButtonPressed,
    this.onFormDataChanged,
    this.onFieldChange,
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
  LinkFieldCoordinator? _linkFieldCoordinator;
  StreamSubscription<LinkLoadProgress>? _progressSubscription;
  bool _linkOptionsLoading = false;
  String? _linkOptionsLoadingMessage;
  final Map<String, dynamic> _formData = {};
  late TabController _tabController;
  final List<_FormTab> _tabs = [];
  final Map<String, int> _fieldTabIndex = {};

  @override
  void initState() {
    super.initState();
    _formKey = GlobalKey<FormBuilderState>();

    _formData.addAll(widget.initialData ?? {});

    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !_formData.containsKey(field.fieldname)) {
        _formData[field.fieldname!] ??= field.defaultValue;
      }
    }

    if (widget.linkOptionService != null && widget.useLinkFieldCoordinator) {
      _linkFieldCoordinator = LinkFieldCoordinator(
        meta: widget.meta,
        linkOptionService: widget.linkOptionService!,
        useCoordinator: true,
      );
      _linkFieldCoordinator!.prefetchInitial(_formData);
      _progressSubscription = _linkFieldCoordinator!.progressStream.listen((p) {
        if (mounted) {
          setState(() {
            _linkOptionsLoading = p.loading;
            _linkOptionsLoadingMessage = p.message;
          });
        }
      });
    }

    _fieldFactory =
        widget.customFieldFactory ??
        FieldFactory(
          linkOptionService: widget.linkOptionService,
          linkFieldCoordinator: _linkFieldCoordinator,
        );

    _buildFormStructure();
    _tabController = TabController(
      length: _tabs.isEmpty ? 1 : _tabs.length,
      vsync: this,
    );

    _triggerFetchFromForPrefilledLinks();
  }

  /// Trigger fetch_from for Link fields that already have values in _formData
  /// so dependent fields (e.g. patient_name from patient) get populated.
  /// Called from both initState and didUpdateWidget.
  void _triggerFetchFromForPrefilledLinks() {
    if (widget.fetchLinkedDocument == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final field in widget.meta.fields) {
        if (field.fieldtype == 'Link' && field.fieldname != null) {
          final val = _formData[field.fieldname];
          if (val != null && val.toString().trim().isNotEmpty) {
            _handleFetchFrom(field.fieldname!, val);
          }
        }
      }
    });
  }

  String _formatDurationPatchedValue(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  List<String> _normalizeMultiSelectPatchedValue(dynamic value) {
    if (value == null) return <String>[];
    if (value is List) {
      return value.map((item) => item.toString()).toList();
    }
    final raw = value.toString();
    if (raw.isEmpty) return <String>[];
    return raw
        .split(',')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  dynamic _normalizePatchedValue(DocField field, dynamic value) {
    switch (field.fieldtype) {
      case FieldTypes.date:
      case FieldTypes.datetime:
        if (value == null || value == '') return null;
        if (value is DateTime) return value;
        if (value is String) return DateTime.tryParse(value);
        return null;

      case FieldTypes.time:
        if (value == null || value == '') return null;
        if (value is DateTime) return value;
        if (value is TimeOfDay) {
          return DateTime(2000, 1, 1, value.hour, value.minute);
        }
        if (value is String) {
          final parts = value.split(':');
          if (parts.length >= 2) {
            final hour = int.tryParse(parts[0]);
            final minute = int.tryParse(parts[1]);
            if (hour != null && minute != null) {
              return DateTime(2000, 1, 1, hour, minute);
            }
          }
        }
        return null;

      case FieldTypes.check:
        if (value is bool) return value;
        if (value is int) return value == 1;
        if (value is String) {
          final normalized = value.trim().toLowerCase();
          return normalized == '1' || normalized == 'true';
        }
        return false;

      case FieldTypes.rating:
        if (value == null || value == '') return null;
        if (value is int) return value;
        return int.tryParse(value.toString());

      case FieldTypes.select:
        if (field.options == null || field.options!.trim().isEmpty) {
          return value?.toString() ?? '';
        }
        if (field.allowMultiple) {
          return _normalizeMultiSelectPatchedValue(value);
        }
        final stringValue = value?.toString();
        return (stringValue == null || stringValue.isEmpty)
            ? null
            : stringValue;

      case FieldTypes.link:
      case FieldTypes.data:
      case FieldTypes.text:
      case FieldTypes.longText:
      case FieldTypes.smallText:
      case FieldTypes.password:
      case FieldTypes.phone:
      case FieldTypes.attach:
      case FieldTypes.attachImage:
      case FieldTypes.image:
      case FieldTypes.readOnly:
        return value?.toString() ?? '';

      case FieldTypes.int:
      case FieldTypes.float:
      case FieldTypes.currency:
      case FieldTypes.percent:
        return value?.toString() ?? '';

      case FieldTypes.duration:
        if (value == null || value == '') return '';
        if (value is int) return _formatDurationPatchedValue(value);
        return value.toString();

      case 'Table':
        if (value is List) return value;
        return <dynamic>[];

      default:
        return value;
    }
  }

  Map<String, dynamic> _normalizePatchValues(Map<String, dynamic> updates) {
    final normalized = <String, dynamic>{};
    for (final entry in updates.entries) {
      final fieldMeta = widget.meta.fields
          .where((f) => f.fieldname == entry.key)
          .cast<DocField?>()
          .firstWhere((f) => f != null, orElse: () => null);
      if (fieldMeta == null) {
        normalized[entry.key] = entry.value ?? '';
        continue;
      }
      normalized[entry.key] = _normalizePatchedValue(fieldMeta, entry.value);
    }
    return normalized;
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

    // Build field -> tab index mapping for focusing invalid fields
    _fieldTabIndex.clear();
    for (var tabIndex = 0; tabIndex < _tabs.length; tabIndex++) {
      final tab = _tabs[tabIndex];
      for (final section in tab.sections) {
        for (final column in section.columns) {
          for (final f in column.fields) {
            final name = f.fieldname;
            if (name != null && name.isNotEmpty) {
              _fieldTabIndex[name] = tabIndex;
            }
          }
        }
      }
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
      _formKey.currentState?.patchValue(_normalizePatchValues(updates));
      if (mounted) setState(() {});

      // Chain: if a patched field is itself a Link, trigger its dependents too.
      // e.g. learner_name → household_survey (Link) → religion, category
      for (final entry in updates.entries) {
        if (entry.value == null || entry.value.toString().trim().isEmpty) {
          continue;
        }
        DocField? updatedFieldMeta;
        for (final f in widget.meta.fields) {
          if (f.fieldname == entry.key) {
            updatedFieldMeta = f;
            break;
          }
        }
        if (updatedFieldMeta?.fieldtype == FieldTypes.link) {
          _handleFetchFrom(entry.key, entry.value.toString());
        }
      }
    } catch (e) {
      debugPrint('FetchFrom error: $e');
    }
  }

  Widget _buildFieldWidget(DocField field) {
    if (!_shouldShowField(field)) {
      // Clear stale data for hidden fields so they don't submit old values
      if (field.fieldname != null && _formData.containsKey(field.fieldname)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _formData.containsKey(field.fieldname)) {
            setState(() {
              _formData.remove(field.fieldname);
            });
          }
        });
      }
      return const SizedBox.shrink();
    }

    final formStyle = widget.style ?? DefaultFormStyle.standard;
    var decoration = formStyle.fieldDecoration?.call(field);
    if (widget.translate != null && decoration != null) {
      final labelText = widget.translate!(field.label ?? field.fieldname ?? '');
      decoration = decoration.copyWith(
        labelText: labelText,
        hintText: field.placeholder != null
            ? widget.translate!(field.placeholder!)
            : decoration.hintText,
        helperText: field.description != null
            ? widget.translate!(field.description!)
            : decoration.helperText,
      );
    }
    final fieldStyle = FieldStyle(
      labelStyle: formStyle.labelStyle,
      descriptionStyle: formStyle.descriptionStyle,
      decoration: decoration,
      translate: widget.translate,
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
                  linkOptionService: widget.linkOptionService,
                  useLinkFieldCoordinator: widget.useLinkFieldCoordinator,
                  fileUrlBase: widget.fileUrlBase,
                  imageHeaders: widget.imageHeaders,
                  // fetch linked document for child doctype.
                  fetchLinkedDocument: widget.fetchLinkedDocument,
                  translate: widget.translate,
                  onButtonPressed: widget.onButtonPressed,
                  onFieldChange: widget.onFieldChange,
                )
          : null,
      onButtonPressed: widget.onButtonPressed,
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

          // Sync FormBuilder internal state (needed for programmatic updates e.g. auto-select)
          if (field.fieldname != null && oldValue != value) {
            _formKey.currentState?.patchValue({
              field.fieldname!: _normalizePatchedValue(field, value),
            });
          }

          // If value changed, clear dependent link fields that depend on this field
          if (oldValue != value && field.fieldname != null) {
            for (final otherField in widget.meta.fields) {
              if (otherField.fieldtype == 'Link' &&
                  otherField.linkFilters != null &&
                  // Check if other field's link filters depend on this field ignoring spaces
                  RegExp(
                    'eval\\s*:\\s*doc\\.${field.fieldname}',
                  ).hasMatch(otherField.linkFilters ?? "")) {
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

          // Computed fields: call onFieldChange and patch hidden field values
          if (oldValue != value &&
              field.fieldname != null &&
              widget.onFieldChange != null) {
            final patches = widget.onFieldChange!(
              field.fieldname!,
              value,
              Map<String, dynamic>.from(_formData),
            );
            if (patches != null && patches.isNotEmpty) {
              _formData.addAll(patches);
              // Sync UI state so visible fields reflect computed values.
              _formKey.currentState?.patchValue(patches);
            }
          }

          // Trigger rebuild to update dependent fields
          if (oldValue != value) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {});
                _emitFormDataChanged();
              }
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

    // Evaluate section-level depends_on — hide entire section if condition is false
    if (!_shouldShowField(section.sectionField)) {
      return const SizedBox.shrink();
    }

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
            SizedBox(
              width: double.infinity,
              child: Text(
                widget.translate != null
                    ? widget.translate!(section.sectionField.displayLabel)
                    : section.sectionField.displayLabel,
                style:
                    formStyle.sectionTitleStyle ??
                    Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                maxLines: formStyle.sectionTitleMaxLines ?? 3,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
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
      _progressSubscription?.cancel();
      _linkFieldCoordinator?.dispose();
      _linkFieldCoordinator = null;
      _formKey = GlobalKey<FormBuilderState>();
      _formData.clear();
      if (widget.initialData != null) {
        _formData.addAll(widget.initialData!);
      }
      for (final field in widget.meta.fields) {
        if (field.fieldname != null &&
            !field.hidden &&
            !_formData.containsKey(field.fieldname)) {
          _formData[field.fieldname!] ??= field.defaultValue;
        }
      }
      if (widget.linkOptionService != null && widget.useLinkFieldCoordinator) {
        _linkFieldCoordinator = LinkFieldCoordinator(
          meta: widget.meta,
          linkOptionService: widget.linkOptionService!,
          useCoordinator: true,
        );
        _linkFieldCoordinator!.prefetchInitial(_formData);
        _progressSubscription = _linkFieldCoordinator!.progressStream.listen((
          p,
        ) {
          if (mounted) {
            setState(() {
              _linkOptionsLoading = p.loading;
              _linkOptionsLoadingMessage = p.message;
            });
          }
        });
      }
      _fieldFactory.linkFieldCoordinator = _linkFieldCoordinator;
      _buildFormStructure();
      _tabController.dispose();
      _tabController = TabController(
        length: _tabs.isEmpty ? 1 : _tabs.length,
        vsync: this,
      );

      _triggerFetchFromForPrefilledLinks();
    }
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _linkFieldCoordinator?.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _handleSubmit() {
    final state = _formKey.currentState;
    if (state == null) return;

    final isValid = state.saveAndValidate();
    if (!isValid) {
      // Switch to tab containing the first invalid field so user sees the error.
      for (final field in widget.meta.fields) {
        final name = field.fieldname;
        if (name == null || name.isEmpty) continue;
        final fieldState = state.fields[name];
        if (fieldState != null && fieldState.hasError) {
          final tabIndex = _fieldTabIndex[name];
          if (tabIndex != null && _tabs.length > 1) {
            setState(() {
              _tabController.index = tabIndex;
            });
          }
          break;
        }
      }
      return;
    }

    // Save all form fields first to ensure FormBuilder captures all values
    state.save();

    // Get all form values from FormBuilder (includes all fields)
    final formValues = Map<String, dynamic>.from(state.value);

    // Merge with _formData (fields that were changed via onChanged)
    formValues.addAll(_formData);

    // Build complete form data with ALL fields from metadata
    // This ensures we save complete data, not just changed fields
    final completeFormData = <String, dynamic>{};

    // First, initialize all fields from metadata with their default/initial values
    // Skip non-data fields (Button, HTML, Image, etc.) - they hold no form value
    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !field.hidden && field.isDataField) {
        // Priority: formValues > initialData > defaultValue > empty value
        completeFormData[field.fieldname!] =
            formValues[field.fieldname] ??
            widget.initialData?[field.fieldname] ??
            field.defaultValue ??
            (field.fieldtype == 'Check'
                ? 0
                : (field.fieldtype == 'Table' ||
                      field.fieldtype == 'Table MultiSelect')
                ? <dynamic>[]
                : '');
      }
    }

    // Then override with any form values (user input takes precedence)
    // But skip null values for Table fields — ChildTableField is not a
    // FormBuilderField, so state.value returns null for Table fields even
    // when _formData has the actual child row data.
    for (final entry in formValues.entries) {
      if (entry.value != null) {
        completeFormData[entry.key] = entry.value;
      }
    }

    widget.onSubmit?.call(completeFormData);
  }

  /// Builds current form data (same structure as submit). Used for dirty detection.
  Map<String, dynamic> _getCurrentFormData() {
    final state = _formKey.currentState;
    final formValues = state != null
        ? Map<String, dynamic>.from(state.value)
        : <String, dynamic>{};
    formValues.addAll(_formData);
    final complete = <String, dynamic>{};
    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !field.hidden && field.isDataField) {
        complete[field.fieldname!] =
            formValues[field.fieldname] ??
            widget.initialData?[field.fieldname] ??
            field.defaultValue ??
            (field.fieldtype == 'Check'
                ? 0
                : (field.fieldtype == 'Table' ||
                      field.fieldtype == 'Table MultiSelect')
                ? <dynamic>[]
                : '');
      }
    }
    for (final entry in formValues.entries) {
      if (entry.value != null) {
        complete[entry.key] = entry.value;
      }
    }
    return complete;
  }

  void _emitFormDataChanged() {
    widget.onFormDataChanged?.call(_getCurrentFormData());
  }

  @override
  Widget build(BuildContext context) {
    if (_tabs.isEmpty) {
      return const Center(child: Text('No fields to display'));
    }
    widget.registerSubmit?.call(_handleSubmit);

    final formStyle = widget.style ?? DefaultFormStyle.standard;

    return FormBuilder(
      key: _formKey,
      child: Column(
        children: [
          if (_linkOptionsLoading)
            Material(
              elevation: 0,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _linkOptionsLoadingMessage ?? 'Loading options...',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_tabs.length > 1)
            TabBar(
              controller: _tabController,
              isScrollable: true,
              tabs: _tabs
                  .map(
                    (tab) => Tab(
                      child: Text(
                        widget.translate != null
                            ? widget.translate!(tab.tabField.displayLabel)
                            : tab.tabField.displayLabel,
                        maxLines: formStyle.tabTitleMaxLines ?? 2,
                        overflow: TextOverflow.ellipsis,
                        softWrap: true,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
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
