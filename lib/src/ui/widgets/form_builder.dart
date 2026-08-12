import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../models/doc_type_meta.dart';
import '../../models/doc_field.dart';
import '../../models/link_filter_result.dart';
import '../../constants/field_types.dart';
import '../../services/link_option_service.dart';
import '../../services/link_field_coordinator.dart';
import '../../utils/depends_on_evaluator.dart';
import '../../utils/field_normalizer.dart';
import '../../utils/sdk_log.dart';
import '../../utils/translate.dart';
import 'fields/field_factory.dart';
import 'fields/base_field.dart';
import 'default_form_style.dart';
import '../form/form_controller.dart';
import '../form/field_ui_state.dart';

export 'fields/link_field_picker_mode.dart';

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

/// Called when a field value changes. Returns a map of computed field updates
/// (e.g. for hidden computed fields) or null when there is nothing to patch.
///
/// The [formData] argument is a snapshot — mutating it does not alter the
/// SDK's internal form state. Return patches to apply changes.
typedef FieldChangeHandler =
    Map<String, dynamic>? Function(
      String fieldName,
      dynamic newValue,
      Map<String, dynamic> formData, {
      ChangeSource source,
    });

/// Called before save with the current form data. Return a non-null error
/// message to block the save and surface the message to the user; return
/// null to allow the save to proceed.
///
/// Use this for DB-independent rules (range checks, regex, conditional
/// mandatory, cross-field rules) that can be evaluated against [data]
/// alone — so the user sees the error at save-time rather than at sync-time.
typedef FormValidator = String? Function(Map<String, dynamic> data);

/// Layout mode for form tab headers.
enum FormTabHeaderLayout { tabBar, stepper }

/// Selects the form's state-management path.
///
/// [legacy] (default) uses the whole-form `setState`-on-change model.
/// [reactive] drives the form from an app-ownable [FormController] with
/// per-field notifiers, so a change rebuilds only the affected fields.
/// The legacy path is retained intact as the rollout safety valve.
enum FormBuilderMode { legacy, reactive }

/// Visual style for stepper tab header mode.
class FormStepHeaderStyle {
  final Color activeColor;
  final Color inactiveColor;
  final Color inactiveTextColor;
  final Color textColor;
  final double dotSize;
  final double lineHeight;
  final double labelsTopGap;
  final double edgePadding;
  final TextStyle? numberTextStyle;
  final TextStyle? labelTextStyle;

  const FormStepHeaderStyle({
    this.activeColor = const Color(0xFF2DD4BF),
    this.inactiveColor = const Color(0xFFD1D5DB),
    this.inactiveTextColor = const Color(0xFF6B7280),
    this.textColor = const Color(0xFF111827),
    this.dotSize = 34.0,
    this.lineHeight = 2.0,
    this.labelsTopGap = 10.0,
    this.edgePadding = 8.0,
    this.numberTextStyle,
    this.labelTextStyle,
  });
}

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

  /// Header layout used when there are multiple tabs.
  final FormTabHeaderLayout tabHeaderLayout;

  /// Optional style when [tabHeaderLayout] is [FormTabHeaderLayout.stepper].
  final FormStepHeaderStyle? stepHeaderStyle;

  /// Whether to show labels above each field widget.
  final bool showFieldLabel;

  /// Whether to show field descriptions below each field widget.
  final bool showFieldDescription;

  /// Optional section card color.
  final Color? sectionCardColor;

  /// Custom input formatters builder for text fields
  final List<TextInputFormatter>? Function(DocField field)? inputFormatters;

  final LinkFieldPickerMode linkFieldPickerMode;

  /// Optional bounds evaluators for Date Pickers
  final DateTime? Function(String doctype, DocField field)? getFirstDate;
  final DateTime? Function(String doctype, DocField field)? getLastDate;

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
    this.tabHeaderLayout = FormTabHeaderLayout.tabBar,
    this.stepHeaderStyle,
    this.showFieldLabel = true,
    this.showFieldDescription = true,
    this.sectionCardColor,
    this.inputFormatters,
    this.linkFieldPickerMode = LinkFieldPickerMode.inline,
    this.getFirstDate,
    this.getLastDate,
  });
}

/// Main form builder widget that renders Frappe forms based on metadata
class FrappeFormBuilder extends StatefulWidget {
  /// State-management path. Defaults to [FormBuilderMode.legacy]; opt into
  /// [FormBuilderMode.reactive] per-screen to get per-field rebuilds.
  final FormBuilderMode mode;

  /// Optional app-owned controller (reactive mode). If null in reactive mode,
  /// the SDK creates and owns one internally so existing call sites work.
  final FormController? controller;

  /// Debug-only per-field build counter (asserted by widget tests). Reactive path.
  static final Map<String, int> debugFieldBuildCounts = {};

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

  /// Fires when [registerSubmit]'s callback was invoked but form
  /// validation rejected the submit attempt. Use this to stop a
  /// parent-managed loading indicator that was started before triggering
  /// submit. Does not fire on successful submit ([onSubmit] does).
  final VoidCallback? onValidationFailed;

  /// If set, field labels, section titles and tab labels are passed through this (e.g. sdk.translations.translate).
  final String Function(String)? translate;

  /// Called when a Button field is pressed. [FormScreen] adapts [OnButtonPressedCallback] to this.
  final ButtonPressedCallback? onButtonPressed;

  /// Called when form data changes (any field value). Use to detect dirty state.
  final void Function(Map<String, dynamic> currentData)? onFormDataChanged;

  /// Called when a field value changes. Returns a map of computed field updates
  /// to patch into the form (e.g. for hidden computed fields).
  final FieldChangeHandler? onFieldChange;

  /// Parent form data when this builder renders a child-table row.
  /// Null for top-level forms.
  final Map<String, dynamic>? parentFormData;

  /// Looks up a filter builder by doctype + fieldname. Returns null when
  /// the app has no custom filter for that field.
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
  getLinkFilterBuilder;

  /// LEGACY mode only. When true, a value set programmatically by an
  /// [onFieldChange] handler's returned patch re-fires THAT field's own change
  /// pipeline, so a computed field that feeds another computed field cascades
  /// (Frappe Desk `frm.set_value` parity). Default `false` preserves the legacy
  /// behaviour where programmatic patches did not cascade.
  ///
  /// Loop safety is value-equality (a field re-fires only when its value
  /// actually changed, so the cascade converges) plus a hard depth cap
  /// ([_maxProgrammaticCascadeDepth]); a handler that never converges is stopped
  /// at the cap and logged via `sdkLog` (bounded degradation, not a crash).
  ///
  /// IMPORTANT: because each cascade hop re-runs the change pipeline,
  /// [onFieldChange] is invoked MORE THAN ONCE for a single user edit (once per
  /// hop, 2–4× for a typical chain). Cascade re-fires are tagged
  /// [ChangeSource.reaction]; the originating user edit is [ChangeSource.user].
  /// Handlers enabled under this flag MUST be effectively pure — return patches
  /// only, no side-effects (analytics, snackbars, counters). A handler that
  /// must run a side-effect exactly once should gate it on
  /// `source == ChangeSource.user`.
  ///
  /// NOTE: this flag is IGNORED in [FormBuilderMode.reactive] — the reactive
  /// [FormController] has its own propagation loop and does not consult it.
  final bool cascadeProgrammaticChanges;

  const FrappeFormBuilder({
    super.key,
    this.mode = FormBuilderMode.legacy,
    this.controller,
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
    this.onValidationFailed,
    this.translate,
    this.onButtonPressed,
    this.onFormDataChanged,
    this.onFieldChange,
    this.parentFormData,
    this.getLinkFilterBuilder,
    this.cascadeProgrammaticChanges = false,
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
    with TickerProviderStateMixin {
  late GlobalKey<FormBuilderState> _formKey;
  late final FieldFactory _fieldFactory;
  LinkFieldCoordinator? _linkFieldCoordinator;
  StreamSubscription<LinkLoadProgress>? _progressSubscription;
  bool _linkOptionsLoading = false;
  String? _linkOptionsLoadingMessage;
  final Map<String, dynamic> _formData = {};

  /// > 0 while a programmatic-patch `patchValue` is being applied under
  /// [FrappeFormBuilder.cascadeProgrammaticChanges]. The `patchValue` re-fires
  /// this field's `onChanged` synchronously (didChange → onChanged); for typed
  /// fields [FieldNormalizer] can change the value's representation, so that
  /// echo would NOT self-guard and would double-run the pipeline alongside the
  /// explicit cascade (PR#83 finding #1). This flag makes the echo a pure
  /// state-sync no-op so the explicit [_scheduleProgrammaticCascade] is the
  /// single cascade path. Only raised when the cascade flag is on, so legacy
  /// behaviour is unchanged.
  int _programmaticEchoGuard = 0;

  /// Cached `fieldname → DocField` index for O(1) lookups (see [_fieldByName]),
  /// keyed by the [DocTypeMeta] it was built from so it self-invalidates when a
  /// parent rebuilds this widget with a different `meta`.
  DocTypeMeta? _fieldIndexMeta;
  Map<String, DocField>? _fieldIndexCache;

  /// `fieldname → DocField` for [widget.meta], rebuilt lazily whenever the meta
  /// reference changes. Avoids the O(n) `meta.fields` scan on hot paths (e.g.
  /// the programmatic cascade, which resolves each patched field per hop).
  Map<String, DocField> get _fieldByName {
    if (!identical(_fieldIndexMeta, widget.meta)) {
      _fieldIndexMeta = widget.meta;
      _fieldIndexCache = {
        for (final f in widget.meta.fields)
          if (f.fieldname != null) f.fieldname!: f,
      };
    }
    return _fieldIndexCache!;
  }

  late TabController _tabController;
  final List<_FormTab> _tabs = [];
  final Map<String, int> _fieldTabIndex = {};

  /// Per-fieldname inline error for child-table (Table / Table MultiSelect)
  /// fields, which are NOT FormBuilderFields — so `_formKey…invalidate()`
  /// cannot surface their required-empty error. The mandatory sweep writes
  /// here and [ChildTableField] renders it; cleared on the next edit.
  final Map<String, String> _tableFieldErrors = {};

  /// Field types whose widget surfaces a required-empty error through
  /// [_tableFieldErrors] rather than `FormBuilderState.fields[…].invalidate()`
  /// — neither is a `FormBuilderField`, so `invalidate()` is a silent no-op.
  static bool _rendersInlineTableError(String? fieldtype) =>
      fieldtype == 'Table' || fieldtype == 'Table MultiSelect';

  /// Pushes the two per-form inputs onto [FieldFactory] as instance state.
  ///
  /// These are deliberately NOT `createField` parameters: that method is
  /// documented as overridable, and Dart requires an override to redeclare
  /// every named parameter of the method it overrides — so a new parameter
  /// breaks every existing subclass at compile time, and a default value does
  /// not help (a caller holding a `FieldFactory` reference may still pass it
  /// explicitly). Host apps subclass this factory, so the signature is treated
  /// as frozen. Mirrors how `linkOptionService` / `linkFieldCoordinator` are
  /// already wired. Re-invoked from [didUpdateWidget] because `meta` can change.
  void _configureFieldFactoryForMeta() {
    // Frappe stores Single doctypes as mediumtext and exempts them from the
    // implicit Data varchar(140) cap.
    _fieldFactory.capDataLength = !widget.meta.isSingle;
    _fieldFactory.errorTextResolver = _inlineTableErrorFor;
  }

  /// Inline error for a child-table field, for whichever mode is active.
  /// Returns null for every other fieldtype — those ARE `FormBuilderField`s and
  /// render their own error, so supplying one here would double-render.
  String? _inlineTableErrorFor(String fieldname) {
    if (!_rendersInlineTableError(widget.meta.getField(fieldname)?.fieldtype)) {
      return null;
    }
    final c = _controller;
    if (widget.mode == FormBuilderMode.reactive && c != null) {
      return c.errorOf(fieldname);
    }
    return _tableFieldErrors[fieldname];
  }

  // Reactive mode (FormBuilderMode.reactive): app-ownable controller.
  FormController? _controller;
  bool _ownsController = false;
  StreamSubscription<String>? _scrollSub;

  void _syncTabFromController() {
    if (!mounted || _controller == null) return;
    final i = _controller!.activeTab.value;
    if (_tabController.index != i && i >= 0 && i < _tabController.length) {
      _tabController.animateTo(i);
    }
  }

  void _syncControllerFromTab() {
    if (_controller == null || _tabController.indexIsChanging) return;
    _controller!.goToTab(_tabController.index); // short-circuits if equal
  }

  void _handleScrollRequest(String field) {
    // Cross-tab navigation is already covered by activeTab sync; in-view scroll
    // is best-effort and intentionally a no-op here (the field's tab is shown).
  }

  /// Parent form data for filter resolution. Equals [_formData] when this
  /// builder is a top-level form (not a child-row form).
  Map<String, dynamic> get effectiveParentFormData =>
      widget.parentFormData ?? _formData;

  TabController get tabController => _tabController;

  void _attachTabControllerListener() {
    _tabController.addListener(() {
      if (!mounted) return;
      // Rebuild to keep custom stepper header in sync with active tab.
      setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    _formKey = GlobalKey<FormBuilderState>();

    _formData.addAll(widget.initialData ?? {});

    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !_formData.containsKey(field.fieldname)) {
        final defVal = field.defaultValue;
        if (defVal != null &&
            field.fieldtype == 'Date' &&
            defVal.toLowerCase() == 'today') {
          final now = DateTime.now();
          _formData[field.fieldname!] =
              '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
        } else {
          _formData[field.fieldname!] ??= defVal;
        }
      }
    }

    if (widget.linkOptionService != null && widget.useLinkFieldCoordinator) {
      _linkFieldCoordinator = LinkFieldCoordinator(
        meta: widget.meta,
        linkOptionService: widget.linkOptionService!,
        useCoordinator: true,
        parentFormData: effectiveParentFormData,
        getLinkFilterBuilder: widget.getLinkFilterBuilder,
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
    // Custom factories supplied by the host won't have these wired in
    // their own constructor — they're host-internal services exposed
    // here so override factories (e.g. SNF's SnfFieldFactory) can
    // still produce Link/etc. fields without their pickers being half-
    // configured on first build. Default-constructed FieldFactory above
    // sets both directly; this branch handles the custom case.
    if (widget.customFieldFactory != null) {
      _fieldFactory.linkOptionService ??= widget.linkOptionService;
      _fieldFactory.linkFieldCoordinator ??= _linkFieldCoordinator;
    }
    _configureFieldFactoryForMeta();

    _buildFormStructure();
    _tabController = TabController(
      length: _tabs.isEmpty ? 1 : _tabs.length,
      vsync: this,
    );
    _attachTabControllerListener();
    _triggerFetchFromForPrefilledLinks();

    if (widget.mode == FormBuilderMode.reactive) {
      _controller =
          widget.controller ??
          FormController(meta: widget.meta, initialData: widget.initialData);
      _ownsController = widget.controller == null;
      _controller!.fetchLinkedDocument = widget.fetchLinkedDocument;
      // no-clobber: only wire the bridge hook if the controller has none.
      if (widget.onFieldChange != null &&
          _controller!.onFieldReaction == null) {
        _controller!.onFieldReaction = widget.onFieldChange;
      }
      // Backward-compat bridge: emit a coalesced snapshot once per flush.
      _controller!.addListener(_emitReactiveFormDataChanged);
      // Reporter wiring: tab <-> controller, scroll requests.
      _controller!.activeTab.addListener(_syncTabFromController);
      _scrollSub = _controller!.scrollRequests.listen(_handleScrollRequest);
      _tabController.addListener(_syncControllerFromTab);
    }
  }

  void _emitReactiveFormDataChanged() {
    final c = _controller;
    if (c == null) return;
    widget.onFormDataChanged?.call(c.buildSubmitData());
  }

  /// Reactive submit: validate via the controller, then emit the payload or
  /// surface validation failure — mirrors the legacy [_handleSubmit] contract.
  Future<void> _handleReactiveSubmit() async {
    final c = _controller;
    if (c == null) return;
    // Await async/server/duplicate validators before committing the submit.
    if (await c.validateAsync()) {
      widget.onSubmit?.call(c.buildSubmitData());
    } else {
      final invalid = c.firstInvalidField;
      if (invalid != null) {
        c.requestFocus(invalid);
        // requestFocus only scrolls editable text into view; explicitly scroll
        // so non-text invalid fields (dropdowns, multiselects, links) land in
        // view too. Post-frame so any focus-driven layout settles first.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) c.scrollToField(invalid);
        });
      }
      widget.onValidationFailed?.call();
    }
  }

  /// Trigger fetch_from for Link fields that already have values in _formData
  /// so dependent fields (e.g. patient_name from patient) get populated.
  /// Called from both initState and didUpdateWidget.
  void _triggerFetchFromForPrefilledLinks() {
    if (widget.fetchLinkedDocument == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Reactive mode: the controller is the single source of truth. The
      // legacy patchValue path below only updates flutter_form_builder field
      // state, which reactive Link targets (value-sourced from the controller)
      // never read — so prefilled fetch_from must run through the controller.
      final c = _controller;
      if (widget.mode == FormBuilderMode.reactive && c != null) {
        c.runInitialFetchFrom();
        return;
      }
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
      normalized[entry.key] = FieldNormalizer.normalize(fieldMeta, entry.value);
    }
    return normalized;
  }

  /// The number of tabs [_buildFormStructure] will actually produce for [meta]
  /// — i.e. the live `_tabs.length`, which is what the [TabController] length
  /// must match.
  ///
  /// A plain count of `Tab Break` fields is NOT equivalent and must not be used
  /// for the [didUpdateWidget] rebuild guard: [_buildFormStructure] skips
  /// `hidden` fields (so a hidden Tab Break yields no tab) and synthesises an
  /// implicit leading "Details" tab when content precedes the first Tab Break.
  /// Counting raw Tab Break fields would miss both, letting the guard skip a
  /// needed [TabController] rebuild and crash with a length/`_tabs` mismatch.
  static int _effectiveTabCount(DocTypeMeta meta) {
    var tabs = 0;
    var sawContentBeforeFirstTab = false;
    var inTab = false;
    for (final field in meta.fields) {
      if (field.hidden) continue;
      final type = field.fieldtype;
      if (type == FieldTypes.tabBreak) {
        tabs++;
        inTab = true;
      } else if (type != FieldTypes.sectionBreak &&
          type != FieldTypes.columnBreak) {
        // A real content field outside any tab → implicit "Details" tab.
        if (!inTab) sawContentBeforeFirstTab = true;
      }
    }
    if (sawContentBeforeFirstTab) tabs++;
    return tabs;
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

  /// Evaluates a `depends_on` expression against the current form data,
  /// returning [defaultValue] when [expr] is null or empty. Shared by
  /// [_shouldShowField], [_isFieldRequired], and [_isFieldReadOnly] so a
  /// future change to `DependsOnEvaluator.evaluate` (e.g. adding a parent
  /// context parameter) applies to all three guards at once.
  /// Data source for depends_on evaluation: the controller's values in reactive
  /// mode (single source of truth), else the legacy _formData map — overlaid
  /// with programmatic READ-ONLY values from the live [FrappeFormBuilder.initialData].
  ///
  /// Why the overlay: a read-only field (e.g. a computed `qty_variance`) never
  /// flows through this widget's own `onChanged`, so a value a caller sets
  /// programmatically (an onFieldChange handler patching the shared, in-place
  /// mutated `initialData` map) never reaches `_formData`. Without this, a
  /// depends_on gate keyed on that field — e.g. a rejection child table shown
  /// when `qty_variance > 0` — would never re-evaluate as true on a rebuild.
  /// Only READ-ONLY fields are overlaid and the live `initialData` value wins
  /// for them; editable fields keep `_formData` (so user edits/clears still win,
  /// and immutable callers are unaffected since `_formData` is seeded from
  /// `initialData` at init).
  /// Per-build memo for the merged legacy overlay. Reset at the top of every
  /// [build] (see [_resetEvalDataCache]).
  ///
  /// Only the merge path is memoised, and only that path allocates: reactive
  /// mode returns `_controller!.values` and legacy mode returns `_formData`,
  /// both by reference. The copy fires solely in legacy mode with non-empty
  /// `initialData` AND at least one read-only field — where a form carrying
  /// several `depends_on` / `mandatory_depends_on` / `read_only_depends_on`
  /// expressions rebuilt the whole map once per expression per build.
  Map<String, dynamic>? _evalDataMemo;

  void _resetEvalDataCache() => _evalDataMemo = null;

  Map<String, dynamic> get _evalData {
    if (widget.mode == FormBuilderMode.reactive && _controller != null) {
      return _controller!.values;
    }
    final init = widget.initialData;
    final ro = _readOnlyFieldNames;
    if (init == null || init.isEmpty || ro.isEmpty) return _formData;
    final memo = _evalDataMemo;
    if (memo != null) return memo;
    final merged = Map<String, dynamic>.from(_formData);
    for (final n in ro) {
      if (init.containsKey(n)) merged[n] = init[n];
    }
    return _evalDataMemo = merged;
  }

  DocTypeMeta? _readOnlyNamesMeta;
  Set<String>? _readOnlyNamesCache;

  /// Cached set of read-only fieldnames, rebuilt when the [DocTypeMeta] changes.
  /// Used by [_evalData] to overlay programmatic read-only values (see there).
  Set<String> get _readOnlyFieldNames {
    if (!identical(_readOnlyNamesMeta, widget.meta) ||
        _readOnlyNamesCache == null) {
      _readOnlyNamesMeta = widget.meta;
      _readOnlyNamesCache = {
        for (final f in widget.meta.fields)
          if (f.fieldname != null && f.fieldname!.isNotEmpty && f.readOnly)
            f.fieldname!,
      };
    }
    return _readOnlyNamesCache!;
  }

  /// [defaultValue] answers an ABSENT expression; [onError] answers one that is
  /// present but cannot be evaluated. They are deliberately separate — see
  /// [DependsOnEvaluator.evaluate].
  bool _evaluateDepends(
    String? expr,
    bool defaultValue, {
    required bool onError,
  }) {
    if (expr == null || expr.isEmpty) return defaultValue;
    return DependsOnEvaluator.evaluate(expr, _evalData, onError: onError);
  }

  bool _shouldShowField(DocField field) =>
      // An unparseable expression shows the field rather than hiding data.
      _evaluateDepends(field.dependsOn, true, onError: true);

  bool _isFieldRequired(DocField field) =>
      field.reqd ||
      // NEVER become mandatory because an expression failed to parse — that
      // would block the save with nothing the user could do to satisfy it.
      _evaluateDepends(field.mandatoryDependsOn, false, onError: false);

  bool _isFieldReadOnly(DocField field) =>
      field.readOnly ||
      // Likewise, never lock a field because an expression failed to parse.
      _evaluateDepends(field.readOnlyDependsOn, false, onError: false);

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

      // Chain: if a patched field is itself a Link, trigger its dependents too.
      // e.g. picking a parent Link cascades to the child's own Link fields.
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

  /// Builds the [FieldStyle] (decoration + label/description handling +
  /// mandatory `*`) for a field. Shared by the legacy and reactive build paths.
  FieldStyle _fieldStyleFor(
    DocField field,
    bool effectiveReqd,
    FrappeFormStyle formStyle,
  ) {
    var decoration = formStyle.fieldDecoration?.call(field);
    if (widget.translate != null && decoration != null) {
      final labelText = widget.translate!(field.label ?? field.fieldname ?? '');
      decoration = decoration.copyWith(
        // When showFieldLabel=true, BaseField renders the external label above
        // the box; setting labelText here would produce a second floating label
        // inside the box. Only set it when there is no external label.
        labelText: formStyle.showFieldLabel ? null : labelText,
        hintText: field.placeholder != null
            ? widget.translate!(field.placeholder!)
            : (formStyle.showFieldLabel ? decoration.hintText : labelText),
        // When showFieldDescription=true, BaseField renders the description
        // below the box; setting helperText here would duplicate it.
        helperText: formStyle.showFieldDescription
            ? null
            : (field.description != null
                  ? widget.translate!(field.description!)
                  : decoration.helperText),
      );
    }

    // Render the mandatory indicator (`*`) on the visible label.
    if (effectiveReqd && decoration != null && !formStyle.showFieldLabel) {
      final labelTxt = decoration.labelText;
      if (labelTxt != null && labelTxt.isNotEmpty && !labelTxt.endsWith(' *')) {
        decoration = decoration.copyWith(labelText: '$labelTxt *');
      } else {
        final hintTxt = decoration.hintText;
        if (hintTxt != null && hintTxt.isNotEmpty && !hintTxt.endsWith(' *')) {
          decoration = decoration.copyWith(hintText: '$hintTxt *');
        }
      }
    }

    return FieldStyle(
      labelStyle: formStyle.labelStyle,
      descriptionStyle: formStyle.descriptionStyle,
      decoration: decoration,
      translate: widget.translate,
      showLabel: formStyle.showFieldLabel,
      showDescription: formStyle.showFieldDescription,
      inputFormatters: formStyle.inputFormatters?.call(field),
      linkFieldPickerMode: formStyle.linkFieldPickerMode,
      getFirstDate: formStyle.getFirstDate != null
          ? (f) => formStyle.getFirstDate!(widget.meta.name, f)
          : null,
      getLastDate: formStyle.getLastDate != null
          ? (f) => formStyle.getLastDate!(widget.meta.name, f)
          : null,
    );
  }

  /// Returns a copy of [field] with the effective reqd/readOnly folded in.
  /// Shared by the legacy and reactive build paths.
  DocField _withEffectiveProps(
    DocField field,
    bool effectiveReqd,
    bool effectiveReadOnly,
  ) {
    return DocField(
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
      searchIndex: field.searchIndex,
    );
  }

  /// Hard cap on programmatic-cascade recursion depth (see
  /// [FrappeFormBuilder.cascadeProgrammaticChanges]). Real chains are 2–4 deep;
  /// this is a backstop against a non-converging
  /// [FrappeFormBuilder.onFieldChange], not a limit on normal use.
  static const int _maxProgrammaticCascadeDepth = 12;

  /// Applies a legacy-mode field-value change through the full pipeline
  /// (internal-state sync, dependent-link clearing, `fetch_from`,
  /// [FrappeFormBuilder.onFieldChange], depends_on rebuild). Extracted from the
  /// field `onChanged` callback so a value set programmatically can re-enter the
  /// SAME pipeline when [FrappeFormBuilder.cascadeProgrammaticChanges] is on —
  /// see [_scheduleProgrammaticCascade]. When the flag is off this is
  /// byte-identical to the previous inline `onChanged`.
  ///
  /// [cascadeDepth] > 0 marks a programmatic cascade re-fire: the field's value
  /// is already in [_formData] (the parent patch set it), so `oldValue == value`
  /// and the normal guard would no-op the pipeline. Forcing it here mirrors
  /// Frappe Desk, where `frm.set_value` fires the change trigger for a
  /// programmatic set too. Loop safety is value-equality (in
  /// [_scheduleProgrammaticCascade]) plus [_maxProgrammaticCascadeDepth].
  void _onFieldValueChanged(
    DocField field,
    dynamic value, {
    int cascadeDepth = 0,
  }) {
    final cascade = widget.cascadeProgrammaticChanges;

    // Echo from a programmatic `patchValue` (see [_programmaticEchoGuard]): under
    // cascade the explicit re-fire (cascadeDepth > 0, dispatched post-frame after
    // the guard is released) is the sole re-fire path, so this synchronous echo
    // only syncs form state and returns without re-running the pipeline.
    if (cascade && _programmaticEchoGuard > 0 && cascadeDepth == 0) {
      if (field.fieldname != null) {
        if (value == null) {
          _formData.remove(field.fieldname);
        } else {
          _formData[field.fieldname!] = value;
        }
      }
      return;
    }

    setState(() {
      // A user edit (e.g. adding a child-table row) clears any pending
      // required-empty-table error surfaced by the mandatory sweep. Keyed on
      // fieldname alone — no fieldtype gate — so it covers Table and
      // Table MultiSelect alike.
      //
      // A still-empty value is NOT such an edit: it does not satisfy the
      // requirement, so the message stays accurate. This also matters for
      // correctness rather than just tidiness — TableMultiSelectFieldBase
      // emits `onChanged(<empty list>)` on mount (its clean-value echo), so a
      // sweep that switches to a lazily-built tab would otherwise have the
      // error it just surfaced wiped on the very next frame.
      if (!(value == null || (value is List && value.isEmpty))) {
        _tableFieldErrors.remove(field.fieldname);
      }
      final oldValue = _formData[field.fieldname];
      // A programmatic re-fire (cascadeDepth > 0) forces the pipeline even
      // though the value is already present in _formData.
      final changed = oldValue != value || cascadeDepth > 0;
      if (value == null) {
        if (field.fieldname != null) {
          _formData.remove(field.fieldname);
        }
      } else {
        if (field.fieldname != null) {
          _formData[field.fieldname!] = value;
        }
      }

      // Sync FormBuilder internal state (needed for programmatic updates e.g.
      // auto-select). Under cascade this patchValue re-fires onChanged with a
      // possibly-renormalized value; guard it so that echo does NOT double-run
      // the pipeline alongside the explicit cascade (PR#83 #1). Guarded only
      // when cascading, so legacy behaviour is byte-identical.
      if (field.fieldname != null && oldValue != value) {
        if (cascade) _programmaticEchoGuard++;
        try {
          _formKey.currentState?.patchValue({
            field.fieldname!: FieldNormalizer.normalize(field, value),
          });
        } finally {
          if (cascade) _programmaticEchoGuard--;
        }
      }

      // If value changed, clear dependent link fields that depend on this field
      if (changed && field.fieldname != null) {
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
      if (changed &&
          field.fieldname != null &&
          value != null &&
          value.toString().trim().isNotEmpty) {
        _handleFetchFrom(field.fieldname!, value);
      }

      // Notify external listener. Pass a snapshot so handlers cannot
      // accidentally mutate _formData; they must return patches instead.
      if (changed && field.fieldname != null) {
        // A cascade re-fire (cascadeDepth > 0) is not a user edit — tag it as
        // ChangeSource.reaction (matching the reactive controller) so hosts can
        // guard side-effects with `if (source == ChangeSource.user)`. The
        // original user edit (depth 0) stays ChangeSource.user, which is the
        // typedef default, so legacy consumers see no change.
        final patches = widget.onFieldChange?.call(
          field.fieldname!,
          value,
          Map<String, dynamic>.from(_formData),
          source: cascadeDepth > 0 ? ChangeSource.reaction : ChangeSource.user,
        );
        if (patches != null && patches.isNotEmpty) {
          // Snapshot prior values BEFORE applying so a cascade can tell a real
          // change from a no-op echo (the value-equality loop breaker).
          final prior = <String, dynamic>{
            for (final key in patches.keys) key: _formData[key],
          };
          _formData.addAll(patches);
          // The self-key widget patch (handler patched the field currently
          // dispatching its own change) is DEFERRED one frame — UNCONDITIONALLY,
          // regardless of the cascade flag. Patching it synchronously re-enters
          // the text field's didChange notification stack and, when the handler
          // rewrote the value ('hi'→'HI'), the in-flight editing value
          // alternates with the patch → unbounded synchronous recursion
          // (StackOverflowError; proven by the "self-referential rewrite must
          // not recurse" test, which crashes if this is made synchronous even
          // with the flag off). _formData above already holds the value; only
          // the widget sync waits a frame.
          final selfKey =
              field.fieldname != null && patches.containsKey(field.fieldname)
              ? field.fieldname
              : null;
          final rest = selfKey == null
              ? patches
              : (Map<String, dynamic>.from(patches)..remove(selfKey));
          if (rest.isNotEmpty) {
            // Echo suppression is only needed while cascading (so the sync
            // patchValue echo doesn't double-run the pipeline); no-op otherwise.
            if (cascade) _programmaticEchoGuard++;
            try {
              _formKey.currentState?.patchValue(_normalizePatchValues(rest));
            } finally {
              if (cascade) _programmaticEchoGuard--;
            }
          }
          if (selfKey != null) {
            final selfValue = patches[selfKey];
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (cascade) _programmaticEchoGuard++;
              try {
                _formKey.currentState?.patchValue(
                  _normalizePatchValues({selfKey: selfValue}),
                );
              } finally {
                if (cascade) _programmaticEchoGuard--;
              }
            });
          }
          // Cascade re-fire (Frappe set_value parity) is flag-gated.
          if (cascade) {
            _scheduleProgrammaticCascade(patches, prior, cascadeDepth);
          }
        }
      }

      // Notify dirty-state listener after the frame settles. No extra setState
      // here: the enclosing setState already rebuilds with the updated
      // _formData, re-evaluating every field's depends_on/mandatory_depends_on
      // in the same frame.
      if (changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _emitFormDataChanged();
          }
        });
      }
    });
  }

  /// Frappe `set_value` parity: for each field in [patches] whose value ACTUALLY
  /// changed (value-equality vs [prior]), re-fire the change pipeline on the next
  /// frame (deferred to avoid a nested `setState`). A converged field re-emits
  /// its current value ⇒ equal ⇒ no re-fire, so the cascade reaches a fixpoint;
  /// [_maxProgrammaticCascadeDepth] backstops a non-converging handler.
  void _scheduleProgrammaticCascade(
    Map<String, dynamic> patches,
    Map<String, dynamic> prior,
    int depth,
  ) {
    if (depth >= _maxProgrammaticCascadeDepth) {
      // A cascade that never converges is a host bug: onFieldChange keeps
      // emitting new values for the same fields. The cap is a deliberate
      // bounded-degradation backstop (NOT a hard failure — a generic SDK must
      // not crash consumer apps here); the loop stops and the form keeps
      // whatever value was current at the cap. The SDK cannot recover the
      // "correct" value from a divergent handler, so this is logged loudly for
      // developers rather than surfaced to the end user.
      sdkLog(
        'FrappeFormBuilder.cascadeProgrammaticChanges: onFieldChange did NOT '
        'converge within $_maxProgrammaticCascadeDepth cascade hops — stopping. '
        'A computed-field handler is emitting a new value on every pass; ensure '
        'it reaches a fixpoint (emits no further change once inputs are stable). '
        'The form may show a half-computed value.',
      );
      return;
    }
    for (final entry in patches.entries) {
      final newValue = entry.value;
      // Child-table payloads are patched wholesale, not treated as field edits.
      if (newValue is List || newValue is Map) continue;
      // Value-equality: skip fields whose value did not actually change.
      if (_normForCascade(prior[entry.key]) == _normForCascade(newValue)) {
        continue;
      }
      final field = _fieldByName[entry.key];
      if (field == null) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _onFieldValueChanged(field, newValue, cascadeDepth: depth + 1);
        }
      });
    }
  }

  /// Normalise for cascade value-equality: trimmed string form, so `5`/`"5"`
  /// compare equal and a null/absent value never spuriously "changes".
  static String? _normForCascade(dynamic v) => v?.toString().trim();

  Widget _buildFieldWidget(DocField field) {
    if (widget.mode == FormBuilderMode.reactive && _controller != null) {
      return _buildReactiveField(field);
    }
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

    // Compute effective reqd / readonly first so the decoration below can
    // reflect the current state of `mandatory_depends_on` (not just the
    // static `reqd` flag).
    final effectiveReqd = _isFieldRequired(field);
    final effectiveReadOnly = _isFieldReadOnly(field) || widget.readOnly;

    final fieldStyle = _fieldStyleFor(field, effectiveReqd, formStyle);

    final fieldWithEffectiveProps = _withEffectiveProps(
      field,
      effectiveReqd,
      effectiveReadOnly,
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
      parentFormData: effectiveParentFormData,
      getLinkFilterBuilder: widget.getLinkFilterBuilder,
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
                  parentFormData: effectiveParentFormData,
                  getLinkFilterBuilder: widget.getLinkFilterBuilder,
                  cascadeProgrammaticChanges: widget.cascadeProgrammaticChanges,
                )
          : null,
      onButtonPressed: widget.onButtonPressed,
      onChanged: (value) => _onFieldValueChanged(field, value),
      enabled: !effectiveReadOnly,
      formData: Map<String, dynamic>.from(_formData),
      style: fieldStyle,
      onIsLocalChanged: (isLocal) {
        // Picker tells us whether the chosen target is local-only
        // (mobile_uuid) or server-known. Mirror that into the
        // `<field>__is_local` companion so [LocalWriter] persists it
        // and [UuidRewriter] can rewrite the value at push time.
        final fname = field.fieldname;
        if (fname == null) return;
        final companion = '${fname}__is_local';
        setState(() {
          _formData[companion] = isLocal ? 1 : 0;
        });
        _formKey.currentState?.patchValue({companion: isLocal ? 1 : 0});
      },
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

  /// Returns true if at least one data field in the section is currently visible.
  /// Matches Frappe Desk behavior: a section header is hidden when all its fields
  /// are hidden by their own depends_on, even if the section's own depends_on passes.
  bool _hasAnyVisibleField(_FormSection section) {
    return section.columns.any(
      (col) => col.fields.any(
        (field) =>
            field.isDataField && !field.hidden && _shouldShowField(field),
      ),
    );
  }

  Widget _buildSection(_FormSection section) {
    // Reactive: the section must re-evaluate its visibility (its own depends_on
    // AND whether any field is visible) when a gate changes — wrap in a
    // ListenableBuilder keyed on the referenced gate fields. Built once if there
    // are no gates. Per-field reactivity inside is unaffected (_ReactiveFieldHost).
    if (widget.mode == FormBuilderMode.reactive && _controller != null) {
      final refs = <String>{
        ...DependsOnEvaluator.referencedFields(section.sectionField.dependsOn),
        for (final col in section.columns)
          for (final f in col.fields)
            ...DependsOnEvaluator.referencedFields(f.dependsOn),
      };
      if (refs.isNotEmpty) {
        return ListenableBuilder(
          listenable: Listenable.merge([
            for (final r in refs) _controller!.valueOf(r),
          ]),
          builder: (_, _) => _buildSectionContent(section),
        );
      }
    }
    return _buildSectionContent(section);
  }

  Widget _buildSectionContent(_FormSection section) {
    final formStyle = widget.style ?? DefaultFormStyle.standard;

    if (section.columns.isEmpty) return const SizedBox.shrink();

    // Evaluate section-level depends_on — hide entire section if condition is false
    if (!_shouldShowField(section.sectionField)) {
      return const SizedBox.shrink();
    }

    // Hide section header when all its fields are hidden (matches Frappe Desk behavior).
    // This covers cases where the section's depends_on passes but no field inside is visible.
    if (!_hasAnyVisibleField(section)) {
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
      color: formStyle.sectionCardColor,
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

  Widget _buildStepHeader(FrappeFormStyle formStyle) {
    final stepStyle = formStyle.stepHeaderStyle ?? const FormStepHeaderStyle();
    final currentStep = _tabController.index + 1;
    final titles = _tabs
        .map(
          (tab) => widget.translate != null
              ? widget.translate!(tab.tabField.displayLabel)
              : tab.tabField.displayLabel,
        )
        .toList();

    Widget buildDot(int step) {
      final isCompleted = step < currentStep;
      final isActive = step == currentStep;
      final bg = isCompleted || isActive ? stepStyle.activeColor : Colors.white;
      final border = isCompleted || isActive
          ? stepStyle.activeColor
          : stepStyle.inactiveColor;
      final fg = isCompleted
          ? Colors.white
          : (isActive ? Colors.white : stepStyle.inactiveTextColor);

      final numberStyle =
          stepStyle.numberTextStyle ??
          TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1.0,
            color: fg,
          );
      final child = isCompleted
          ? const Icon(Icons.check, size: 18, color: Colors.white)
          : Text('$step', style: numberStyle);

      return InkWell(
        onTap: () => _tabController.animateTo(step - 1),
        customBorder: const CircleBorder(),
        child: Container(
          width: stepStyle.dotSize,
          height: stepStyle.dotSize,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            border: Border.all(color: border, width: 2),
          ),
          child: Center(child: child),
        ),
      );
    }

    Widget buildLabel(String text, bool active, int step) {
      final mergedStyle =
          stepStyle.labelTextStyle?.copyWith(
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? stepStyle.textColor : stepStyle.inactiveTextColor,
          ) ??
          TextStyle(
            fontSize: 12,
            height: 1.2,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? stepStyle.textColor : stepStyle.inactiveTextColor,
          );
      return InkWell(
        onTap: () => _tabController.animateTo(step - 1),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: formStyle.tabTitleMaxLines ?? 2,
          overflow: TextOverflow.ellipsis,
          style: mergedStyle,
        ),
      );
    }

    return SizedBox(
      height: stepStyle.dotSize + stepStyle.labelsTopGap + 34.0,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth - (stepStyle.edgePadding * 2);
          final stepCount = titles.length;
          final dx = stepCount <= 1
              ? 0.0
              : (w - stepStyle.dotSize) / (stepCount - 1);

          double leftForStep(int step) =>
              stepStyle.edgePadding + (step - 1) * dx;
          double centerXForStep(int step) =>
              leftForStep(step) + stepStyle.dotSize / 2;

          Widget lineSegment(int fromStep, int toStep, bool active) {
            final left = centerXForStep(fromStep);
            final right = centerXForStep(toStep);
            return Positioned(
              left: left,
              top: stepStyle.dotSize / 2 - stepStyle.lineHeight / 2,
              width: (right - left),
              height: stepStyle.lineHeight,
              child: Container(
                color: active ? stepStyle.activeColor : stepStyle.inactiveColor,
              ),
            );
          }

          Widget labelAt(int step, String text, bool active) {
            return Positioned(
              left: leftForStep(step) - 18,
              top: stepStyle.dotSize + stepStyle.labelsTopGap,
              width: stepStyle.dotSize + 36,
              child: buildLabel(text, active, step),
            );
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 1; i < stepCount; i++)
                lineSegment(i, i + 1, currentStep > i),
              for (var i = 1; i <= stepCount; i++)
                Positioned(left: leftForStep(i), top: 0, child: buildDot(i)),
              for (var i = 1; i <= stepCount; i++)
                labelAt(i, titles[i - 1], currentStep == i),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTabHeader(FrappeFormStyle formStyle) {
    if (_tabs.length <= 1) return const SizedBox.shrink();
    if (formStyle.tabHeaderLayout == FormTabHeaderLayout.stepper) {
      return _buildStepHeader(formStyle);
    }
    return TabBar(
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
    );
  }

  @override
  void didUpdateWidget(FrappeFormBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initialDataChanged = !mapEquals(
      oldWidget.initialData,
      widget.initialData,
    );
    final metaChanged =
        oldWidget.meta.name != widget.meta.name ||
        _effectiveTabCount(oldWidget.meta) != _effectiveTabCount(widget.meta);
    if (initialDataChanged || metaChanged) {
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
          parentFormData: effectiveParentFormData,
          getLinkFilterBuilder: widget.getLinkFilterBuilder,
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
      _configureFieldFactoryForMeta();
      _buildFormStructure();
      _tabController.dispose();
      _tabController = TabController(
        length: _tabs.isEmpty ? 1 : _tabs.length,
        vsync: this,
      );
      _attachTabControllerListener();
      _triggerFetchFromForPrefilledLinks();
    }
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _linkFieldCoordinator?.dispose();
    _scrollSub?.cancel();
    if (_controller != null) {
      // Tear down everything we attached — the controller may be app-owned and
      // outlive this widget; stale subscriptions would fire into a defunct State.
      _controller!.removeListener(_emitReactiveFormDataChanged);
      _controller!.activeTab.removeListener(_syncTabFromController);
      _tabController.removeListener(_syncControllerFromTab);
      if (_ownsController) _controller!.dispose();
    }
    _tabController.dispose();
    super.dispose();
  }

  void _handleSubmit() {
    final state = _formKey.currentState;
    if (state == null) return;

    final isValid = state.saveAndValidate();
    if (!isValid) {
      // Switch to tab containing the first invalid field so user sees the error.
      String? firstInvalidField;
      for (final field in widget.meta.fields) {
        final name = field.fieldname;
        if (name == null || name.isEmpty) continue;
        final fieldState = state.fields[name];
        if (fieldState != null && fieldState.hasError) {
          firstInvalidField = name;
          final tabIndex = _fieldTabIndex[name];
          if (tabIndex != null && _tabs.length > 1) {
            setState(() {
              _tabController.index = tabIndex;
            });
          }
          break;
        }
      }

      // Smooth scroll to the first invalid field element
      if (firstInvalidField != null) {
        Future.delayed(const Duration(milliseconds: 150), () {
          if (!mounted) return;
          Element? errorElement;
          void findErrorRecursive(Element element) {
            if (errorElement != null) return;
            final state = element is StatefulElement ? element.state : null;
            if (state is FormFieldState && state.hasError) {
              errorElement = element;
              return;
            }
            element.visitChildren(findErrorRecursive);
          }

          context.visitChildElements(findErrorRecursive);

          if (errorElement != null) {
            final renderObject = errorElement!.renderObject;
            if (renderObject != null && renderObject.attached) {
              Scrollable.ensureVisible(
                errorElement!,
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCubic,
                alignment: 0.2, // 20% offset from top
              );
            }
          }
        });
      }

      widget.onValidationFailed?.call();
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

    // First, initialize all visible data fields from metadata with their
    // default/initial values. Hidden-by-depends_on fields are skipped so
    // they neither seed defaults nor survive into the save payload — this
    // half of the sweep covers fields with no current value but a stale
    // default; the post-merge sweep below covers fields with stale user
    // input from before the gate flipped.
    for (final field in widget.meta.fields) {
      if (field.fieldname != null && !field.hidden && field.isDataField) {
        if (field.dependsOn != null && field.dependsOn!.isNotEmpty) {
          // Evaluate against the merged formValues so the latest user
          // changes drive the visibility decision.
          if (!DependsOnEvaluator.evaluate(field.dependsOn, formValues)) {
            continue;
          }
        }
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

    // Drop fields the user can't actually see from the save payload,
    // mirroring Frappe Desk's behaviour where hidden-by-depends_on fields
    // are not part of `frm.doc` at save time. A field is "not visible" if
    // its own `depends_on` evaluates false, OR if the enclosing section /
    // tab break's `depends_on` evaluates false (hidden sections
    // short-circuit before their children build, so the build-time clear
    // at `_buildFieldWidget` never runs for them).
    final dataForDepends = Map<String, dynamic>.from(completeFormData);
    final hiddenByContainer = <String>{};
    String? currentSectionDeps;
    String? currentTabDeps;
    for (final f in widget.meta.fields) {
      if (f.fieldtype == 'Tab Break') {
        currentTabDeps = (f.dependsOn != null && f.dependsOn!.isNotEmpty)
            ? f.dependsOn
            : null;
        currentSectionDeps = null;
        continue;
      }
      if (f.fieldtype == 'Section Break') {
        currentSectionDeps = (f.dependsOn != null && f.dependsOn!.isNotEmpty)
            ? f.dependsOn
            : null;
        continue;
      }
      if (f.fieldtype == 'Column Break') continue;
      if (f.fieldname == null) continue;
      final tabHidden =
          currentTabDeps != null &&
          !DependsOnEvaluator.evaluate(currentTabDeps, dataForDepends);
      final secHidden =
          currentSectionDeps != null &&
          !DependsOnEvaluator.evaluate(currentSectionDeps, dataForDepends);
      if (tabHidden || secHidden) {
        hiddenByContainer.add(f.fieldname!);
      }
    }
    completeFormData.removeWhere((fieldname, _) {
      if (hiddenByContainer.contains(fieldname)) return true;
      final field = widget.meta.fields.firstWhere(
        (f) => f.fieldname == fieldname,
        orElse: () => DocField(fieldtype: '_missing_'),
      );
      if (field.fieldtype == '_missing_') return false;
      if (field.dependsOn == null || field.dependsOn!.isEmpty) return false;
      return !DependsOnEvaluator.evaluate(field.dependsOn, dataForDepends);
    });

    // Frappe-parity mandatory sweep over the COMPLETE payload.
    // `saveAndValidate()` above only covers fields whose widgets are currently
    // MOUNTED — TabBarView builds tab pages lazily, so a reqd field on any
    // other tab (and Table fields, which are not FormBuilderFields) slips
    // through, saves locally, and bounces back as a server 417 at sync time.
    // Mirrors FormController._validateField: visible + effectively-required,
    // missing when null / blank string / empty list (0 and false are "set").
    final missingMandatory = <DocField>[];
    for (final field in widget.meta.fields) {
      final name = field.fieldname;
      if (name == null || name.isEmpty) continue;
      if (field.hidden || !field.isDataField) continue;
      // Absent from the payload = hidden by its own or a container depends_on.
      if (!completeFormData.containsKey(name)) continue;
      final required =
          field.reqd ||
          (field.mandatoryDependsOn != null &&
              field.mandatoryDependsOn!.isNotEmpty &&
              // `onError: false` is NOT optional here. `_isFieldRequired`
              // (same file) passes it, so without it an unparseable
              // `mandatory_depends_on` makes this sweep block Save on a field
              // the widget never marked required and never drew an asterisk
              // on — the dead-Save-button shape this PR fixes for empty child
              // tables, reintroduced through the evaluator.
              DependsOnEvaluator.evaluate(
                field.mandatoryDependsOn,
                dataForDepends,
                onError: false,
              ));
      if (!required) continue;
      final v = completeFormData[name];
      final missing =
          v == null ||
          (v is String && v.trim().isEmpty) ||
          (v is List && v.isEmpty);
      if (missing) missingMandatory.add(field);
    }
    if (missingMandatory.isNotEmpty) {
      final tabIndex = _fieldTabIndex[missingMandatory.first.fieldname];
      if (tabIndex != null &&
          _tabs.length > 1 &&
          _tabController.index != tabIndex) {
        setState(() {
          _tabController.index = tabIndex;
        });
      }
      // A required-empty child table ('Table' -> ChildTableField) or
      // 'Table MultiSelect' (-> TableMultiSelectFieldBase) is NOT a
      // FormBuilderField, so the `invalidate()` path below is a no-op for
      // both. Route their errors into `_tableFieldErrors`, which both widgets
      // render inline via their `errorText`. Without this a required-empty
      // Table MultiSelect blocked submit with NO visible message anywhere.
      // Every other field type keeps the invalidate path unchanged.
      final tableErrors = <String, String>{};
      for (final f in missingMandatory) {
        final name = f.fieldname;
        if (name == null) continue;
        if (_rendersInlineTableError(f.fieldtype)) {
          tableErrors[name] = sdkTr('{0} is required', [f.displayLabel]);
        }
      }
      if (tableErrors.isNotEmpty) {
        setState(() {
          _tableFieldErrors
            ..clear()
            ..addAll(tableErrors);
        });
      }
      // Surface inline errors once the target tab's fields have mounted
      // (same delay the invalid-field scroll above uses for tab settling).
      Future.delayed(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        final st = _formKey.currentState;
        for (final f in missingMandatory) {
          if (_rendersInlineTableError(f.fieldtype)) {
            continue; // surfaced via _tableFieldErrors above
          }
          st?.fields[f.fieldname]?.invalidate(
            sdkTr('{0} is required', [f.displayLabel]),
          );
        }
      });
      widget.onValidationFailed?.call();
      return;
    }

    widget.onSubmit?.call(completeFormData);
  }

  /// Assembles the full form data map: every non-hidden data field with
  /// its current value (user input takes precedence), filling in
  /// `initialData` / `defaultValue` / per-fieldtype empties for fields
  /// the user hasn't touched. Shared by [_handleSubmit] (post-validate)
  /// and [_getCurrentFormData] (dirty detection) so the default-value
  /// fallback logic stays consistent between submit and dirty-check.
  Map<String, dynamic> _buildCompleteFormData() {
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

  /// Builds current form data (same structure as submit). Used for dirty detection.
  Map<String, dynamic> _getCurrentFormData() => _buildCompleteFormData();

  void _emitFormDataChanged() {
    widget.onFormDataChanged?.call(_getCurrentFormData());
  }

  /// Reactive build path: structural widgets are built once; each leaf field is
  /// wrapped in a [ListenableBuilder] so a change rebuilds only the affected
  /// field(s). No whole-form setState. The legacy path is untouched.
  Widget _buildReactive(FrappeFormStyle formStyle) {
    widget.registerSubmit?.call(_handleReactiveSubmit);
    return FormBuilder(
      key: _formKey,
      initialValue: _controller!.values,
      child: Column(
        children: [
          _buildTabHeader(formStyle),
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

  /// One reactive leaf field. Rebuilds on its own value OR uiState change only
  /// (typing A bumps A's valueOf; A ∉ affectedBy(A), so uiStateOf alone would
  /// not fire — hence the merge).
  Widget _buildReactiveField(DocField field) {
    final name = field.fieldname;
    if (name == null || name.isEmpty) return const SizedBox.shrink();
    final c = _controller!;
    final formStyle = widget.style ?? DefaultFormStyle.standard;
    // Reactive Link fields must also rebuild when a field referenced by their
    // `link_filters` changes (e.g. District filtered by State): such a source
    // change alters neither this field's own value nor its FieldUiState, so
    // without watching the source notifiers the dropdown keeps stale parent
    // data and stays pinned on "Select <parent> first".
    final linkSources = LinkOptionService.getDependentFieldNames(
      field.linkFilters,
    );
    // Child-table fieldtypes ('Table' / 'Table MultiSelect') are NOT
    // FormBuilderFields, so the controller's validation error has no way to
    // reach the user except the widget's own inline `errorText` — without this
    // a required-empty child table blocked Save with nothing on screen.
    // Every other fieldtype IS a FormBuilderField that renders its own error;
    // feeding it `errorText` too would double-render, so the channel (and the
    // extra error listener that repaints it) stays gated to these two.
    final inlineTableError = _rendersInlineTableError(field.fieldtype);
    return _ReactiveFieldHost(
      name: name,
      controller: c,
      watch: linkSources,
      watchError: inlineTableError,
      build: (ui) {
        if (!ui.visible) return const SizedBox.shrink();
        FrappeFormBuilder.debugFieldBuildCounts[name] =
            (FrappeFormBuilder.debugFieldBuildCounts[name] ?? 0) + 1;
        // Form-level readOnly (e.g. workflow freeze) must disable every field,
        // mirroring the legacy path (`_isFieldReadOnly(field) || widget.readOnly`).
        final effectiveReadOnly = ui.readOnly || widget.readOnly;
        final effective = _withEffectiveProps(
          field,
          ui.required,
          effectiveReadOnly,
        );
        final fieldStyle = _fieldStyleFor(field, ui.required, formStyle);
        final value = c.getValue(name);
        // Keep flutter_form_builder's internal field state in sync for
        // programmatic / external setValue (FB ignores a changed initialValue on
        // rebuild). The post-frame diff guard + setValue's equality short-circuit
        // prevent a patchValue<->onChanged feedback loop.
        final normalized = FieldNormalizer.normalize(effective, value);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          // The field the user is actively editing owns its own text; a user
          // keystroke already lives in the FB field, so re-patching the
          // normalized value would clobber an in-progress edit (e.g. '7.').
          if (c.lastSourceOf(name) == ChangeSource.user) return;
          final st = _formKey.currentState?.fields[name];
          if (st != null && st.value != normalized) {
            _formKey.currentState?.patchValue({name: normalized});
          }
        });
        final w = _fieldFactory.createField(
          field: effective,
          value: value,
          enabled: !effectiveReadOnly,
          // Inline-table error only: an edit made while the message is showing
          // re-validates the field so supplying a value clears it. Gated on an
          // error ALREADY being displayed, so the empty-list clean-value echo
          // TableMultiSelectFieldBase emits on mount can never create one; when
          // the field is still empty the re-validation re-sets the identical
          // message, which a ValueNotifier<String?> treats as no change — the
          // error the failed submit surfaced survives instead of being wiped.
          onChanged: (v) {
            c.setValue(name, v, source: ChangeSource.user);
            if (inlineTableError && c.errorOf(name) != null) {
              c.validateField(name);
            }
          },
          formData: c.values,
          style: fieldStyle,
          uploadFile: widget.uploadFile,
          fileUrlBase: widget.fileUrlBase,
          imageHeaders: widget.imageHeaders,
          getMeta: widget.getMeta,
          getLinkFilterBuilder: widget.getLinkFilterBuilder,
          onButtonPressed: widget.onButtonPressed,
          // Child tables: the transient row-edit sheet builds its OWN reactive
          // sub-form. It passes no controller, so that FrappeFormBuilder owns +
          // disposes its controller on sheet close (add=create / delete=dispose
          // / reorder fall out of the List<map> model — no per-row machinery).
          childTableFormBuilder: widget.getMeta != null
              ? (childMeta, initialData, onSubmit, {registerSubmit}) =>
                    FrappeFormBuilder(
                      mode: FormBuilderMode.reactive,
                      meta: childMeta,
                      initialData: initialData,
                      onSubmit: onSubmit,
                      registerSubmit: registerSubmit,
                      getMeta: widget.getMeta,
                      linkOptionService: widget.linkOptionService,
                      useLinkFieldCoordinator: widget.useLinkFieldCoordinator,
                      fileUrlBase: widget.fileUrlBase,
                      imageHeaders: widget.imageHeaders,
                      fetchLinkedDocument: widget.fetchLinkedDocument,
                      translate: widget.translate,
                      onButtonPressed: widget.onButtonPressed,
                      onFieldChange: widget.onFieldChange,
                      parentFormData: widget.parentFormData ?? c.values,
                      getLinkFilterBuilder: widget.getLinkFilterBuilder,
                      cascadeProgrammaticChanges:
                          widget.cascadeProgrammaticChanges,
                    )
              : null,
        );
        if (w == null) return const SizedBox.shrink();
        return Padding(
          padding:
              formStyle.fieldPadding ?? const EdgeInsets.only(bottom: 16.0),
          child: w,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Drop the per-build eval-data memo. Safe as a build-scoped cache because
    // every reader (`_shouldShowField` / `_isFieldRequired` /
    // `_isFieldReadOnly`, via `_hasAnyVisibleField`, `_buildFieldWidget` and
    // `_buildSectionContent`) runs inside this build; `_formData` mutations all
    // go through setState, which lands here again before anything re-reads it.
    _resetEvalDataCache();
    if (_tabs.isEmpty) {
      return const Center(child: Text('No fields to display'));
    }
    final formStyle = widget.style ?? DefaultFormStyle.standard;

    if (widget.mode == FormBuilderMode.reactive && _controller != null) {
      return _buildReactive(formStyle);
    }

    widget.registerSubmit?.call(_handleSubmit);

    return FormBuilder(
      key: _formKey,
      initialValue: Map<String, dynamic>.from(_formData),
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
          _buildTabHeader(formStyle),
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

/// Reactive leaf-field host. Rebuilds on its own uiState OR value change only,
/// and reports semantic lifecycle: mounted/unmounted on its own-depends_on
/// visibility toggle (host stays in tree, renders SizedBox) AND on disposal
/// (section/tab removal) — the widget is the only thing that knows the true
/// rendered state, since the controller's uiState ignores container depends_on.
class _ReactiveFieldHost extends StatefulWidget {
  const _ReactiveFieldHost({
    required this.name,
    required this.controller,
    required this.build,
    this.watch = const <String>[],
    this.watchError = false,
  });
  final String name;
  final FormController controller;
  final Widget Function(FieldUiState ui) build;

  /// Also rebuild when this field's validation error changes. Only child-table
  /// fieldtypes need it: they paint the controller's error through their own
  /// inline `errorText`, so without this listener the message is computed on
  /// submit and never painted. FormBuilderField-backed types surface their own
  /// error and stay off this notifier (no extra rebuilds for them).
  final bool watchError;

  /// Extra field names whose value notifiers also trigger a rebuild — e.g. the
  /// fields a Link field references via `link_filters`. A change to one of them
  /// alters neither this field's own value nor its FieldUiState, but the field
  /// must re-read form data to re-resolve its filtered options.
  final List<String> watch;

  @override
  State<_ReactiveFieldHost> createState() => _ReactiveFieldHostState();
}

class _ReactiveFieldHostState extends State<_ReactiveFieldHost> {
  bool _reportedVisible = false;

  void _sync(bool visible) {
    if (visible == _reportedVisible) return;
    _reportedVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (visible) {
        widget.controller.reportFieldMounted(widget.name);
      } else {
        widget.controller.reportFieldUnmounted(widget.name);
        widget.controller.unregisterFieldContext(widget.name);
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.controller.uiStateOf(widget.name),
      widget.controller.valueOf(widget.name),
      for (final f in widget.watch) widget.controller.valueOf(f),
      // Subscribing also CREATES the error notifier, which validate() only
      // pushes to when it already exists — so the listener must be registered
      // here, before the first submit, for the message to ever arrive.
      if (widget.watchError) widget.controller.errorListenableOf(widget.name),
    ]),
    builder: (context, _) {
      final ui = widget.controller.uiStateOf(widget.name).value;
      _sync(ui.visible);
      // Register this field's render context while it is visible so the
      // controller can scroll it into view by name (e.g. first invalid field
      // on submit). Off-screen fields are still registered — the form body is
      // a single eager scroll view — but depends_on-hidden fields are not.
      if (ui.visible) {
        widget.controller.registerFieldContext(widget.name, context);
      }
      return widget.build(ui);
    },
  );

  @override
  void dispose() {
    if (_reportedVisible) widget.controller.reportFieldUnmounted(widget.name);
    widget.controller.unregisterFieldContext(widget.name);
    super.dispose();
  }
}
