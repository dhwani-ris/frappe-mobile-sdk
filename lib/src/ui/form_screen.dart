import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api/client.dart';
import '../api/exceptions.dart';
import '../api/utils.dart';
import '../utils/translate.dart';
import '../models/doc_field.dart';
import '../models/doc_type_meta.dart';
import '../models/document.dart';
import '../models/link_filter_result.dart';
import '../models/outbox_row.dart';
import '../models/workflow_transition.dart';
import '../services/link_option_service.dart';
import '../services/meta_service.dart';
import '../models/image_pick_source.dart';
import '../services/media_resolver.dart';
import '../services/offline_repository.dart';
import '../services/sync_controller.dart';
import '../services/sync_service.dart';
import '../services/workflow_service.dart';
import '../utils/uuid_pattern.dart';
import 'widgets/screen_helpers.dart';
import 'widgets/sync_error_banner.dart';
import 'widgets/form_builder.dart'
    show
        FrappeFormBuilder,
        FrappeFormStyle,
        FormBuilderMode,
        OnButtonPressedCallback,
        FieldChangeHandler,
        FormValidator;
import 'form/form_controller.dart' show FormController;
import 'widgets/fields/field_factory.dart' show FieldFactory;
import '../utils/attachment_paths.dart';
import '../utils/sdk_log.dart';

/// Visual customization for [FormScreen] action area.
class FormScreenStyle {
  final Color? appBarBackgroundColor;
  final ButtonStyle? saveButtonStyle;
  final Color? deleteIconColor;

  const FormScreenStyle({
    this.appBarBackgroundColor,
    this.saveButtonStyle,
    this.deleteIconColor,
  });
}

/// Screen for displaying and editing a Frappe document form.
/// When [api] is set, CRUD is done directly on the server then local repo is updated.
class FormScreen extends StatefulWidget {
  final DocTypeMeta meta;
  final Document? document;
  final OfflineRepository repository;
  final SyncService? syncService;
  final LinkOptionService? linkOptionService;
  final MetaService? metaService;

  /// When set, save/delete go to server first; local repo is updated after success.
  final FrappeClient? api;
  final Function()? onSaveSuccess;

  /// When set, new documents created from this screen will include mobile_uuid on the server.
  final Future<String?> Function()? getMobileUuid;

  /// Optional form style (overrides the default style used by FrappeFormBuilder).
  final FrappeFormStyle? style;

  /// Force read-only mode (no editing, no save/delete).
  final bool readOnly;

  /// Explicit permission flags for save/delete buttons. If null, defaults to allowed.
  final bool? canSave;
  final bool? canDelete;

  /// If set, doctype label and field labels are translated (e.g. sdk.translations.translate).
  final String Function(String)? translate;

  /// Optional pre-filled data for new documents (overrides document?.data when document is null).
  final Map<String, dynamic>? initialData;

  /// Optional callback when a Button field is pressed. Override to implement client-script logic
  /// (API calls, dialogs, form updates). When null, default behavior applies: if [field.options]
  /// has a server method path, it is called; otherwise a message is shown.
  final OnButtonPressedCallback? onButtonPressed;

  /// Called when a field value changes. Returns computed field patches (for hidden computed fields).
  final FieldChangeHandler? onFieldChange;

  /// Called before save with the current form data. Return a non-null error
  /// message to block the save; return null to allow it to proceed. Use this
  /// for DB-independent rules so the user sees errors at save-time, not
  /// sync-time.
  final FormValidator? validator;

  /// Optional builder for runtime link filters. Called during link option resolution.
  final LinkFilterBuilder? Function(String doctype, String fieldname)?
  getLinkFilterBuilder;

  /// LEGACY mode only — forwarded to [FrappeFormBuilder.cascadeProgrammaticChanges].
  /// When true, a value set by an [onFieldChange] handler's patch re-fires that
  /// field's own change pipeline (Frappe `set_value` parity). Ignored in
  /// [FormBuilderMode.reactive]. Default `false`.
  final bool cascadeProgrammaticChanges;

  /// When true (default), use LinkFieldCoordinator for sequenced link option loading.
  final bool useLinkFieldCoordinator;

  /// Optional visual customization for AppBar/action buttons.
  final FormScreenStyle? screenStyle;

  /// Imperative sync surface for the persistent in-form sync error
  /// banner. When non-null and the document already has stuck outbox
  /// rows (failed/blocked/conflict), a banner above the form lets the
  /// user expand details and tap `Retry`. When null the banner is
  /// suppressed entirely — useful in tests or hosting paths that have
  /// no push engine wired.
  final SyncController? syncController;

  final void Function(void Function() submit)? registerSubmit;
  final bool hideAppBarActions;

  /// When false, the workflow header shows the state chip only (no Actions
  /// button) and workflow transitions are not loaded. Default true.
  final bool showWorkflowActions;
  final void Function(bool isSaving)? onSaveStateChanged;
  final void Function(bool isDirty)? onFormDirtyChanged;
  final Widget? bottomNavigationBar;

  /// State-management path passed to the underlying [FrappeFormBuilder].
  /// Defaults to legacy; set [FormBuilderMode.reactive] for per-field rebuilds.
  final FormBuilderMode mode;

  /// Optional app-owned [FormController] (reactive mode). If null in reactive
  /// mode, FormScreen creates one, exposes it via [onControllerReady], and
  /// disposes it. If provided, the app owns + disposes it.
  final FormController? controller;

  /// Called once with the resolved controller (reactive mode) so the app can
  /// read/listen/mutate form state directly.
  final void Function(FormController controller)? onControllerReady;

  /// Optional factory for rendering custom field widgets, forwarded to the
  /// underlying [FrappeFormBuilder] (which already supports it). Lets hosts
  /// supply an app-specific [FieldFactory] subclass to override field types.
  final FieldFactory? customFieldFactory;

  /// Synchronous last-known connectivity, forwarded to Attach/Image fields.
  /// When it returns false, an offline pick is stored as a durable local path
  /// and queued at save instead of being uploaded inline. When null, fields
  /// attempt the upload and fall back to the local path if it fails — so
  /// correctness holds even if the host does not supply this.
  final bool Function()? isOnline;

  /// Host hook choosing which sources image fields offer — gallery, camera, or
  /// both. Global across doctypes and fields, and read live so a host can flip
  /// it from a setting without rebuilding. Null means both.
  final ImagePickSource Function()? imagePickSource;

  const FormScreen({
    super.key,
    required this.meta,
    this.document,
    required this.repository,
    this.syncService,
    this.linkOptionService,
    this.metaService,
    this.api,
    this.onSaveSuccess,
    this.getMobileUuid,
    this.style,
    this.readOnly = false,
    this.canSave,
    this.canDelete,
    this.translate,
    this.initialData,
    this.onButtonPressed,
    this.onFieldChange,
    this.validator,
    this.getLinkFilterBuilder,
    this.cascadeProgrammaticChanges = false,
    this.useLinkFieldCoordinator = true,
    this.screenStyle,
    this.syncController,
    this.registerSubmit,
    this.hideAppBarActions = false,
    this.showWorkflowActions = true,
    this.onSaveStateChanged,
    this.onFormDirtyChanged,
    this.bottomNavigationBar,
    this.mode = FormBuilderMode.legacy,
    this.controller,
    this.onControllerReady,
    this.customFieldFactory,
    this.isOnline,
    this.imagePickSource,
  });

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> with WidgetsBindingObserver {
  bool _isSaving = false;
  String? _errorMessage;
  void Function()? _triggerSubmit;

  List<WorkflowTransition>? _workflowTransitions;
  bool _workflowLoading = false;
  Map<String, dynamic>? _workflowUpdatedDocData;
  late WorkflowService? _workflowService;

  /// Stuck outbox rows (failed/blocked/conflict) for `widget.document`,
  /// or empty when the document is new or has no errors. Loaded from the
  /// repo in [initState] / [didUpdateWidget] and refreshed on lifecycle
  /// resume + after a Retry tap so the banner reflects the latest state.
  List<OutboxRow> _syncErrorRows = const [];

  /// `pending_attachments.id` → durable local path for this document, so
  /// Attach/Image fields can preview a `pending:<id>` value (offline pick not
  /// yet uploaded) from its local copy. Reloaded wherever the document
  /// (re)loads — initState / didUpdateWidget / resume / after save — so it
  /// never goes stale against the field markers.
  Map<int, String> _pendingAttachmentPaths = const {};

  /// Resolves an attach-field value to a local file for preview. Built once per
  /// screen so the memoised futures inside the field widgets stay stable across
  /// rebuilds. Null when there is no API client to fetch through — the fields
  /// then fall back to their previous network-only behaviour.
  MediaResolver? _mediaResolver;

  /// Fetches the bytes behind a stored attach value, with auth. Returns null on
  /// any failure: a media fetch must never break form rendering.
  ///
  /// STREAMED rather than buffered, and bounded twice, because this is the only
  /// place that sees the response before it occupies memory:
  ///
  /// 1. `Content-Length`, when the server sends one, refuses an oversized body
  ///    without reading a single chunk.
  /// 2. The accumulate loop re-checks as it goes, because a chunked response has
  ///    no declared length and a server may under-report.
  ///
  /// [MediaResolver.maxFetchBytes] repeats the ceiling, but by the time it runs
  /// the allocation has already happened — its job is to keep an oversized body
  /// out of the cache, not out of RAM. The device floor here is API 26, where a
  /// single unbounded attachment can take the process down.
  Future<List<int>?> _fetchMediaBytes(String value) async {
    final api = widget.api;
    if (api == null) return null;
    final url = frappeFileFetchUrl(value, api.baseUrl);
    if (url == null || !url.startsWith('http')) return null;
    const cap = kDefaultMaxMediaFetchBytes;
    http.Client? client;
    try {
      client = http.Client();
      final request = http.Request('GET', Uri.parse(url))
        ..headers.addAll(api.requestHeaders);
      final res = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;

      final declared = res.contentLength;
      if (declared != null && declared > cap) {
        sdkLog(
          'FormScreen._fetchMediaBytes($value): Content-Length $declared '
          'exceeds the $cap byte cap — not fetched',
        );
        return null;
      }

      final bytes = <int>[];
      await for (final chunk in res.stream) {
        bytes.addAll(chunk);
        if (bytes.length > cap) {
          sdkLog(
            'FormScreen._fetchMediaBytes($value): body exceeded the $cap byte '
            'cap mid-stream — aborted',
          );
          return null;
        }
      }
      return bytes;
    } catch (e, st) {
      sdkLog('FormScreen._fetchMediaBytes($value) failed — $e\n$st');
      return null;
    } finally {
      client?.close();
    }
  }

  void _buildMediaResolver() {
    if (widget.api == null) {
      _mediaResolver = null;
      return;
    }
    _mediaResolver = widget.repository.mediaResolver(
      fetch: _fetchMediaBytes,
      isOnline: () => widget.isOnline?.call() ?? true,
    );
  }

  /// Baseline form data for dirty check. When current form data differs, show Save.
  Map<String, dynamic>? _baselineFormData;

  /// Drives the AppBar Save button visibility. Held in a [ValueNotifier]
  /// (not in `setState`) because `_onFormDataChanged` fires on every
  /// keystroke — using `setState` rebuilds the entire FormBuilder tree
  /// per keystroke, which is a non-trivial cost on long forms. The
  /// notifier scopes the rebuild to a single [ValueListenableBuilder] in
  /// the AppBar `actions` list.
  final ValueNotifier<bool> _isFormDirty = ValueNotifier<bool>(false);

  /// Drives the AppBar push-to-server spinner. Held in a [ValueNotifier]
  /// for the same reason as [_isFormDirty]: a long-running push must not
  /// keep the whole form rebuilding while the spinner spins.
  final ValueNotifier<bool> _isSyncing = ValueNotifier<bool>(false);

  Map<String, dynamic> get _currentDocData =>
      _workflowUpdatedDocData ??
      widget.document?.data ??
      widget.initialData ??
      {};

  /// True if document is submitted (docstatus == 1). Form is read-only when submitted.
  bool get _isSubmitted {
    final d = _currentDocData['docstatus'];
    if (d == null) return false;
    if (d == 1) return true;
    if (d == '1') return true;
    return false;
  }

  static bool _formDataEquals(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
    DocTypeMeta meta,
  ) {
    String norm(DocField f, dynamic v) {
      if (f.fieldtype == 'Check') {
        if (v == null) return '0';
        if (v == true) return '1';
        if (v == false) return '0';
        final s = v.toString().trim();
        if (s.isEmpty) return '0';
        return (s == '1' || s.toLowerCase() == 'true') ? '1' : '0';
      }
      return v?.toString().trim() ?? '';
    }

    for (final f in meta.fields) {
      final k = f.fieldname;
      if (k == null || k.isEmpty || f.hidden || !f.isDataField) continue;
      final sa = norm(f, a[k]);
      final sb = norm(f, b[k]);
      if (sa != sb) return false;
    }
    return true;
  }

  void _setSaving(bool value) {
    if (mounted) {
      setState(() {
        _isSaving = value;
      });
      widget.onSaveStateChanged?.call(value);
    }
  }

  void _onFormDataChanged(Map<String, dynamic> currentData) {
    final baseline = _baselineFormData ?? _currentDocData;
    final dirty = !_formDataEquals(currentData, baseline, widget.meta);
    if (mounted) {
      _isFormDirty.value = dirty;
      widget.onFormDirtyChanged?.call(dirty);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _workflowService = widget.api != null ? WorkflowService(widget.api!) : null;
    _buildMediaResolver();
    _baselineFormData = Map<String, dynamic>.from(_currentDocData);
    _loadWorkflowTransitions();
    _loadSyncErrors();
    _loadPendingAttachmentPaths();
    widget.onFormDirtyChanged?.call(false);

    if (widget.mode == FormBuilderMode.reactive) {
      _formController =
          widget.controller ??
          FormController(
            meta: widget.meta,
            initialData: widget.document?.data ?? widget.initialData,
          );
      _ownsFormController = widget.controller == null;
      widget.onControllerReady?.call(_formController!);
    }
  }

  // Reactive mode: resolved controller (app-provided or FormScreen-created).
  FormController? _formController;
  bool _ownsFormController = false;

  // Enclosing route, captured in didChangeDependencies() where the element is
  // guaranteed active. App-lifecycle callbacks read this cached reference
  // instead of calling ModalRoute.of(context): `mounted` stays true during the
  // inactive phase (after deactivate(), before unmount()), so an ancestor
  // lookup there can assert "Looking up a deactivated widget's ancestor".
  ModalRoute<dynamic>? _route;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _isFormDirty.dispose();
    _isSyncing.dispose();
    if (_ownsFormController) _formController?.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Cache the enclosing route while the element is active so lifecycle
    // callbacks never look it up on a deactivated context.
    _route = ModalRoute.of(context);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Every mounted FormScreen subscribed to WidgetsBindingObserver
    // receives this callback on app resume — including off-screen
    // IndexedStack / PageView siblings that stay mounted by design.
    // Without this gate, an N-tab form host hits the outbox DAO N
    // times per foreground. Cap to the form the user is actually
    // looking at. (PR#36 round-2 M14)
    if (!mounted) return;
    // Use the route cached in didChangeDependencies — NOT ModalRoute.of(context)
    // here. `mounted` is still true while an element is inactive (deactivated
    // but not yet unmounted), and an ancestor lookup on such a context asserts
    // "Looking up a deactivated widget's ancestor is unsafe", destabilising the
    // element tree (the cascade then surfaces as `_dependents.isEmpty`).
    final route = _route;
    if (route != null && !route.isCurrent) return;
    _loadSyncErrors();
    _loadPendingAttachmentPaths();
  }

  @override
  void didUpdateWidget(covariant FormScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document?.serverId != widget.document?.serverId ||
        oldWidget.api != widget.api ||
        oldWidget.document?.data != widget.document?.data ||
        oldWidget.initialData != widget.initialData) {
      _workflowTransitions = null;
      _workflowUpdatedDocData = null;
      _buildMediaResolver();
      _workflowService = widget.api != null
          ? WorkflowService(widget.api!)
          : null;
      _baselineFormData = Map<String, dynamic>.from(_currentDocData);
      _isFormDirty.value = false;
      widget.onFormDirtyChanged?.call(false);
      _loadWorkflowTransitions();
      _loadSyncErrors();
      _loadPendingAttachmentPaths();
    }
  }

  Future<void> _loadSyncErrors() async {
    final localId = widget.document?.localId;
    if (localId == null || localId.isEmpty) {
      if (_syncErrorRows.isNotEmpty && mounted) {
        setState(() => _syncErrorRows = const []);
      }
      return;
    }
    try {
      final rows = await widget.repository.getSyncErrorsForDoc(
        doctype: widget.meta.name,
        mobileUuid: localId,
      );
      if (!mounted) return;
      setState(() => _syncErrorRows = rows);
    } catch (e, st) {
      // Banner is best-effort; a query failure should never block the
      // form from rendering.
      sdkLog('FormScreen: _loadSyncErrors failed — $e\n$st');
    }
  }

  Future<void> _loadPendingAttachmentPaths() async {
    final localId = widget.document?.localId;
    if (localId == null || localId.isEmpty) {
      if (_pendingAttachmentPaths.isNotEmpty && mounted) {
        setState(() => _pendingAttachmentPaths = const {});
      }
      return;
    }
    // Skip the DB round-trip for forms that can hold no attachment — either
    // directly (Attach/Attach Image/Image) or inside a child table. Avoids a
    // needless query (and any pending markers) on plain forms.
    final canHoldAttachment = widget.meta.fields.any((f) {
      final t = f.fieldtype;
      return t == 'Attach' ||
          t == 'Attach Image' ||
          t == 'Image' ||
          t == 'Table' ||
          t == 'Table MultiSelect';
    });
    if (!canHoldAttachment) {
      if (_pendingAttachmentPaths.isNotEmpty && mounted) {
        setState(() => _pendingAttachmentPaths = const {});
      }
      return;
    }
    try {
      final map = await widget.repository.pendingAttachmentLocalPaths(localId);
      if (!mounted) return;
      setState(() => _pendingAttachmentPaths = map);
    } catch (e, st) {
      // Preview resolution is best-effort; a lookup failure just falls back to
      // the broken-image placeholder — never blocks the form.
      sdkLog('FormScreen: _loadPendingAttachmentPaths failed — $e\n$st');
    }
  }

  Future<void> _retrySyncRow(int outboxId) async {
    final controller = widget.syncController;
    if (controller == null) return;
    try {
      await controller.retry(outboxId);
    } catch (e, st) {
      sdkLog('FormScreen: retry($outboxId) failed — $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              sdkTr('Retry failed: {0}', [toUserFriendlyMessage(e)]),
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    await _loadSyncErrors();
  }

  /// Drains the outbox without pulling. Upstream rows TierComputer
  /// places ahead of this record go in the same drain.
  Future<void> _handlePushRecord() async {
    final svc = widget.syncService;
    if (svc == null) return;
    _isSyncing.value = true;
    try {
      await svc.pushSync(doctype: widget.meta.name);
    } catch (e, st) {
      sdkLog('FormScreen: pushSync failed — $e\n$st');
      if (mounted) {
        showStatusSnackBar(
          context,
          'Push failed: ${toUserFriendlyMessage(e)}',
          severity: SnackBarSeverity.error,
        );
      }
      return;
    } finally {
      if (mounted) _isSyncing.value = false;
    }
    await _loadSyncErrors();
    if (!mounted) return;
    final stuck = _syncErrorRows.isNotEmpty;
    showStatusSnackBar(
      context,
      stuck ? sdkTr('Push completed with errors') : sdkTr('Pushed'),
      severity: stuck ? SnackBarSeverity.warning : SnackBarSeverity.success,
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _loadWorkflowTransitions() async {
    if (!widget.meta.hasWorkflow ||
        !widget.showWorkflowActions ||
        widget.api == null ||
        widget.document?.serverId == null) {
      return;
    }
    setState(() => _workflowLoading = true);
    try {
      final list = await _workflowService!.getTransitions(
        widget.meta.name,
        widget.document!.serverId!,
      );
      if (mounted) {
        setState(() {
          _workflowTransitions = list;
          _workflowLoading = false;
        });
      }
    } catch (e, st) {
      sdkLog('FormScreen._loadWorkflowTransitions failed — $e\n$st');
      if (mounted) {
        setState(() {
          _workflowTransitions = [];
          _workflowLoading = false;
        });
      }
    }
  }

  Future<void> _applyWorkflowAction(String action) async {
    if (widget.api == null || widget.document?.serverId == null) return;
    try {
      final updated = await _workflowService!.applyWorkflow(
        widget.meta.name,
        widget.document!.serverId!,
        action,
      );
      await widget.repository.saveDocument(
        doctype: widget.meta.name,
        data: {...updated, 'mobile_uuid': widget.document!.localId},
      );
      if (mounted) {
        setState(() {
          _workflowUpdatedDocData = updated;
          _baselineFormData = Map<String, dynamic>.from(updated);
        });
        _isFormDirty.value = false;
        await _loadWorkflowTransitions();
        if (mounted) {
          showStatusSnackBar(
            context,
            'Workflow: $action',
            severity: SnackBarSeverity.success,
          );
        }
      }
    } catch (e, st) {
      sdkLog('FormScreen._applyWorkflowAction($action) failed — $e\n$st');
      if (mounted) {
        showStatusSnackBar(
          context,
          toUserFriendlyMessage(e),
          severity: SnackBarSeverity.error,
        );
      }
    }
  }

  Future<void> _showWorkflowActionsSheet() async {
    if (_workflowLoading) {
      return;
    }
    final stateField = widget.meta.workflowStateField;
    final currentState = stateField != null
        ? _currentDocData[stateField]?.toString()
        : null;

    await showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                title: Text(
                  widget.translate != null
                      ? widget.translate!('Current State')
                      : 'Current State',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  currentState?.isNotEmpty == true ? currentState! : '—',
                ),
              ),
              const Divider(height: 1),
              if (_workflowTransitions == null || _workflowTransitions!.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Text(
                    widget.translate != null
                        ? widget.translate!(
                            'No workflow actions available for this state.',
                          )
                        : sdkTr(
                            'No workflow actions available for this state.',
                          ),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              else
                ..._workflowTransitions!.map((t) {
                  return ListTile(
                    title: Text(t.action),
                    onTap: () {
                      Navigator.pop(context);
                      _applyWorkflowAction(t.action);
                    },
                  );
                }),
            ],
          ),
        );
      },
    );
  }

  Future<void> _handleButtonPressed(
    DocField field,
    Map<String, dynamic> formData,
  ) async {
    final method = field.options?.trim();
    if (method == null || method.isEmpty) {
      if (mounted) {
        showStatusSnackBar(
          context,
          sdkTr(
            '{0}: Action not configured for mobile. This button may use client-side logic only available on web.',
            [field.displayLabel],
          ),
          severity: SnackBarSeverity.warning,
        );
      }
      return;
    }

    if (widget.api == null) {
      if (mounted) {
        showStatusSnackBar(
          context,
          sdkTr('Action unavailable offline'),
          severity: SnackBarSeverity.warning,
        );
      }
      return;
    }

    try {
      await widget.api!.call(method, args: {'doc': formData});
      if (mounted) {
        showStatusSnackBar(
          context,
          sdkTr('Action completed'),
          severity: SnackBarSeverity.success,
        );
      }
    } catch (e, st) {
      sdkLog('FormScreen.action($method) failed — $e\n$st');
      if (mounted) {
        showStatusSnackBar(
          context,
          toUserFriendlyMessage(e),
          severity: SnackBarSeverity.error,
        );
      }
    }
  }

  Future<Map<String, dynamic>?> _fetchLinkedDocument(
    String linkedDoctype,
    String docName,
  ) async {
    // Per-doctype table covers both synced (server_name) and offline-only
    // (mobile_uuid) rows without touching the legacy documents table.
    try {
      final row = await widget.repository.getRowFromPerDoctypeTable(
        linkedDoctype,
        docName,
      );
      if (row != null) return row;
    } catch (e, st) {
      sdkLog(
        'FormScreen: getRowFromPerDoctypeTable($linkedDoctype, $docName) '
        'failed — $e\n$st',
      );
    }
    // If the value is shaped like a mobile_uuid, it is a local identity
    // and must never be looked up on the server — Frappe naming series
    // never produce v4 UUIDs, so `getByName(..., uuid)` is guaranteed
    // to 500. This guards against orphan-link cases (the linked local
    // row was deleted/replaced after sync, or the `<field>__is_local`
    // flag was never set) by failing closed instead of leaking the
    // mobile_uuid out of the device.
    if (looksLikeMobileUuid(docName)) return null;
    if (widget.api != null) {
      try {
        return await widget.api!.doctype.getByName(linkedDoctype, docName);
      } catch (e, st) {
        sdkLog(
          'FormScreen: api.doctype.getByName($linkedDoctype, $docName) '
          'failed — $e\n$st',
        );
      }
    }
    return null;
  }

  Future<void> _handleSubmit(Map<String, dynamic> formData) async {
    // Local-first validation: DB-independent rules run on-device so the user
    // sees errors at save-time rather than at sync-time. Returns null on pass;
    // a non-null String aborts the save and is shown to the user.
    if (widget.validator != null) {
      final error = widget.validator!(formData);
      if (error != null) {
        setState(() {
          _errorMessage = error;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }
    }

    // Normalize multi-select: Frappe expects comma-separated string for plain
    // multi-select fields, but Table / Table MultiSelect fields must remain as
    // List<Map> so Frappe can create child-table rows.
    final payload = Map<String, dynamic>.from(formData);
    for (final f in widget.meta.fields) {
      final name = f.fieldname;
      if (f.allowMultiple && name != null && payload[name] is List) {
        final ft = f.fieldtype;
        if (ft == 'Table' || ft == 'Table MultiSelect') continue;
        payload[name] = (payload[name] as List)
            .map((e) => e.toString())
            .join(',');
      }
    }

    _setSaving(true);
    setState(() {
      _errorMessage = null;
    });

    // Offline-first contract: every save queues to docs__ + outbox;
    // push is driven by the cloud icon / Sync. Server-first below
    // runs only in legacy online-only mode where there is no outbox.
    final offlineEnabled = widget.repository.offlineMode.enabled;
    bool serverReachable = !offlineEnabled && widget.api != null;
    if (serverReachable && widget.syncService != null) {
      try {
        serverReachable = await widget.syncService!.isOnline();
      } catch (e, st) {
        sdkLog('FormScreen.save: isOnline check failed — $e\n$st');
        serverReachable = false;
      }
    }

    try {
      if (widget.api != null && serverReachable) {
        Map<String, dynamic>? savedData;
        // Server-first: create/update on server, then update local.
        // Treat an offline-only document (document!=null but serverId==null)
        // the same as a brand-new doc — the server has never seen it, so we
        // must INSERT, not UPDATE. Forwarding `mobile_uuid` lets Frappe's
        // L2 idempotency match the row when push-back lands.
        final isInsert =
            widget.document == null || widget.document!.serverId == null;
        // True when this save edits a previously-saved offline record
        // (lineage already exists locally with mobile_uuid = localId).
        // Drives both the identity-locking below and the post-save
        // reconcileServerSave path that collapses any failed outbox
        // rows for this same lineage.
        final isEditingExistingDoc = widget.document != null;
        if (isInsert) {
          // Preserve any existing offline data + mobile_uuid from the local doc.
          if (widget.document != null) {
            final existing = Map<String, dynamic>.from(widget.document!.data);
            existing.addAll(payload);
            payload
              ..clear()
              ..addAll(existing);
          }
          if (widget.getMobileUuid != null &&
              (payload['mobile_uuid'] == null ||
                  (payload['mobile_uuid'] as String).isEmpty)) {
            final uuid = await widget.getMobileUuid!();
            if (uuid != null && uuid.isNotEmpty) {
              payload['mobile_uuid'] = uuid;
            }
          }
          // Identity lock: when this is an edit-save of an existing
          // local record, the mobile_uuid is system-owned metadata
          // and MUST equal the document's localId. The form payload
          // and the device-level getMobileUuid callback are both
          // untrusted for this field — a stray empty string from
          // either would otherwise fork lineage (the server generates
          // a fresh UUID, leaving the original docs__ row + failed
          // outbox row orphaned). See `reconcileServerSave` for the
          // companion cleanup that runs after the server replies.
          if (isEditingExistingDoc) {
            payload['mobile_uuid'] = widget.document!.localId;
          }
          final result = await widget.api!.document.createDocument(
            widget.meta.name,
            payload,
          );
          final serverName =
              result['name']?.toString() ?? result['docname']?.toString();
          if (serverName != null) {
            final merged = Map<String, dynamic>.from(payload)
              ..['name'] = serverName;
            // Submit directly for submittable doctypes (no draft)
            if (widget.meta.isSubmittable) {
              await widget.api!.document.submitDocument(
                widget.meta.name,
                serverName,
              );
              merged['docstatus'] = 1;
            }
            if (isEditingExistingDoc) {
              // Collapses lineage: attach server_name to the existing
              // docs__ row, drop the failed outbox row, then apply
              // the server snapshot. Without this, the failed outbox
              // row + dirty docs__ row from the prior failed attempt
              // would stay behind alongside the freshly-synced row.
              await widget.repository.reconcileServerSave(
                doctype: widget.meta.name,
                mobileUuid: widget.document!.localId,
                serverName: serverName,
                serverData: merged,
              );
            } else {
              await widget.repository.applyServerDocument(
                doctype: widget.meta.name,
                serverName: serverName,
                data: merged,
              );
            }
            savedData = merged;
          } else {
            savedData = Map<String, dynamic>.from(payload);
          }
        } else {
          final existingData = Map<String, dynamic>.from(widget.document!.data);
          existingData.addAll(payload);
          await widget.api!.document.updateDocument(
            widget.meta.name,
            widget.document!.serverId!,
            existingData,
          );
          // Submit directly for submittable doctypes when doc is still draft
          if (widget.meta.isSubmittable) {
            final docstatus =
                int.tryParse(existingData['docstatus']?.toString() ?? '0') ?? 0;
            if (docstatus == 0) {
              await widget.api!.document.submitDocument(
                widget.meta.name,
                widget.document!.serverId!,
              );
              existingData['docstatus'] = 1;
            }
          }
          await widget.repository.applyServerDocument(
            doctype: widget.meta.name,
            serverName: widget.document!.serverId!,
            data: existingData,
          );
          savedData = existingData;
        }
        if (mounted) {
          setState(() {
            _baselineFormData = savedData!;
          });
          _isFormDirty.value = false;
          showStatusSnackBar(
            context,
            sdkTr('Saved successfully'),
            severity: SnackBarSeverity.success,
          );
          widget.onSaveSuccess?.call();
        }
        return;
      }

      // Offline / store-then-sync path
      if (widget.document == null) {
        if (widget.getMobileUuid != null) {
          final uuid = await widget.getMobileUuid!();
          if (uuid != null && uuid.isNotEmpty) {
            payload['mobile_uuid'] = uuid;
          }
        }
        await widget.repository.saveDocument(
          doctype: widget.meta.name,
          data: payload,
        );
      } else {
        final existingData = Map<String, dynamic>.from(widget.document!.data);
        existingData.addAll(payload);
        await widget.repository.saveDocument(
          doctype: widget.meta.name,
          data: {...existingData, 'mobile_uuid': widget.document!.localId},
        );
      }

      if (mounted) {
        final savedData =
            widget.document == null
                  ? Map<String, dynamic>.from(payload)
                  : Map<String, dynamic>.from(widget.document!.data)
              ..addAll(payload);
        setState(() {
          _baselineFormData = savedData;
        });
        _isFormDirty.value = false;
        // A save may have queued freshly-picked attachments; refresh the
        // id→local-path map so any `pending:<id>` markers resolve in-place.
        _loadPendingAttachmentPaths();
        showStatusSnackBar(
          context,
          sdkTr('Document saved successfully'),
          severity: SnackBarSeverity.success,
        );
        widget.onSaveSuccess?.call();
      }
    } catch (e, st) {
      sdkLog('FormScreen.save (server-first/offline) failed — $e\n$st');
      if (mounted) {
        setState(() {
          _errorMessage = e is FrappeException
              ? e.message
              : toUserFriendlyMessage(e);
        });
      }
    } finally {
      _setSaving(false);
      // Either branch above may have queued a fresh outbox row or
      // resolved an existing one; refresh the persistent banner.
      _loadSyncErrors();
    }
  }

  Future<void> _handleDelete() async {
    if (widget.document == null) return;

    final confirmed = await showConfirmDialog(
      context,
      title: sdkTr('Delete Document'),
      content: sdkTr('Are you sure you want to delete this document?'),
      confirmLabel: sdkTr('Delete'),
      confirmColor: Colors.red,
    );

    if (confirmed != true) return;

    _setSaving(true);

    try {
      final offlineEnabled = widget.repository.offlineMode.enabled;
      if (!offlineEnabled &&
          widget.api != null &&
          widget.document!.serverId != null) {
        await widget.api!.document.deleteDocument(
          widget.meta.name,
          widget.document!.serverId!,
        );
        // The server doc is gone; drop the local docs__ mirror too, else it
        // reappears in list screens until the next pull (PR#36 round-4 B5).
        await widget.repository.hardDeleteLocalMirror(
          doctype: widget.meta.name,
          mobileUuid: widget.document!.localId,
        );
      } else {
        await widget.repository.deleteDocument(
          doctype: widget.meta.name,
          mobileUuid: widget.document!.localId,
        );
      }

      if (mounted) {
        showStatusSnackBar(
          context,
          sdkTr('Document deleted'),
          severity: SnackBarSeverity.warning,
        );
        // Notify the parent BEFORE popping so the callback runs while this
        // screen is still mounted — a setState/context use inside it would
        // otherwise operate on a defunct element (M8).
        widget.onSaveSuccess?.call();
        Navigator.pop(context);
      }
    } catch (e, st) {
      sdkLog('FormScreen.delete failed — $e\n$st');
      if (mounted) {
        setState(() {
          _errorMessage = e is FrappeException
              ? e.message
              : toUserFriendlyMessage(e);
        });
      }
    } finally {
      _setSaving(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowSave = (widget.canSave ?? true) && !widget.readOnly;
    final allowDelete =
        (widget.canDelete ?? (widget.document != null)) &&
        !widget.readOnly &&
        widget.document != null &&
        !_isSubmitted;

    // `_isFormDirty` and `_isSyncing` are ValueNotifiers, not setState
    // fields — so the heavy FormBuilder tree below does NOT rebuild on
    // every keystroke or while the push spinner is spinning. Only the
    // ValueListenableBuilder closures here re-run. Remaining setState
    // sites in this file (workflow loading, sync-error rows banner,
    // saving spinner) still cause full rebuilds and are tracked as
    // follow-up isolation work.

    final effectiveReadOnly = _isSaving || widget.readOnly || _isSubmitted;

    return Scaffold(
      bottomNavigationBar: widget.bottomNavigationBar,
      appBar: AppBar(
        backgroundColor: widget.screenStyle?.appBarBackgroundColor,
        title: Text(
          widget.translate != null
              ? widget.translate!(widget.meta.label ?? widget.meta.name)
              : (widget.meta.label ?? widget.meta.name),
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: _isFormDirty,
            builder: (context, dirty, _) {
              final showSave = allowSave && (dirty || widget.document == null);
              if (!showSave || widget.hideAppBarActions) {
                return const SizedBox.shrink();
              }
              return TextButton.icon(
                key: const Key('form_save_button'),
                style: widget.screenStyle?.saveButtonStyle,
                onPressed: _isSaving ? null : () => _triggerSubmit?.call(),
                icon: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save),
                label: Text(sdkTr('Save')),
              );
            },
          ),
          if (widget.repository.offlineMode.enabled &&
              widget.syncService != null &&
              !widget.readOnly &&
              !widget.hideAppBarActions)
            ValueListenableBuilder<bool>(
              valueListenable: _isSyncing,
              builder: (context, syncing, _) {
                return IconButton(
                  key: const Key('form_push_button'),
                  icon: syncing
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_upload),
                  onPressed: syncing || _isSaving ? null : _handlePushRecord,
                  tooltip: sdkTr('Push to server'),
                );
              },
            ),
          if (allowDelete && !widget.hideAppBarActions)
            IconButton(
              icon: Icon(
                Icons.delete,
                color: widget.screenStyle?.deleteIconColor,
              ),
              onPressed: _isSaving ? null : _handleDelete,
              tooltip: sdkTr('Delete'),
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              if (_syncErrorRows.isNotEmpty)
                SyncErrorBanner(
                  rows: _syncErrorRows,
                  onRetry: widget.syncController == null ? null : _retrySyncRow,
                ),
              if (_errorMessage != null)
                ErrorMessageBanner(message: _errorMessage!),
              if (widget.meta.hasWorkflow &&
                  widget.document != null &&
                  widget.api != null)
                _WorkflowHeader(
                  meta: widget.meta,
                  documentData: _currentDocData,
                  loading: _workflowLoading,
                  translate: widget.translate,
                  onShowActions: _showWorkflowActionsSheet,
                  showActions: widget.showWorkflowActions,
                ),
              Expanded(
                child: FrappeFormBuilder(
                  key: widget.document != null
                      ? ValueKey('form_${widget.document!.localId}')
                      : const ValueKey('form_new'),
                  mode: widget.mode,
                  controller: _formController,
                  meta: widget.meta,
                  initialData:
                      _workflowUpdatedDocData ??
                      widget.document?.data ??
                      widget.initialData,
                  onSubmit: _handleSubmit,
                  readOnly: effectiveReadOnly,
                  onFormDataChanged: _onFormDataChanged,
                  linkOptionService: widget.linkOptionService,
                  useLinkFieldCoordinator: widget.useLinkFieldCoordinator,
                  customFieldFactory: widget.customFieldFactory,
                  uploadFile: widget.api != null
                      ? (file) async {
                          final res = await widget.api!.attachment.uploadFile(
                            file,
                          );
                          return res['file_url'] as String? ??
                              res['file_name'] as String?;
                        }
                      : null,
                  fileUrlBase: widget.api?.baseUrl,
                  imageHeaders: widget.api?.requestHeaders,
                  isOnline: widget.isOnline,
                  pendingAttachmentPaths: _pendingAttachmentPaths,
                  mediaResolver: _mediaResolver?.resolve,
                  // Read live through the repository so a mid-session toggle
                  // flip takes effect on the next pick.
                  isOfflineMode: () => widget.repository.offlineMode.enabled,
                  imagePickSource: widget.imagePickSource,
                  fetchLinkedDocument: _fetchLinkedDocument,
                  getMeta: widget.metaService != null
                      ? (doctype) => widget.metaService!.getMeta(doctype)
                      : null,
                  registerSubmit: (trigger) {
                    _triggerSubmit = trigger;
                    widget.registerSubmit?.call(trigger);
                  },
                  onButtonPressed: widget.onButtonPressed != null
                      ? (field, formData) => widget.onButtonPressed!(
                          field,
                          formData,
                          _handleButtonPressed,
                        )
                      : _handleButtonPressed,
                  style: widget.style,
                  translate: widget.translate,
                  onFieldChange: widget.onFieldChange,
                  getLinkFilterBuilder: widget.getLinkFilterBuilder,
                  cascadeProgrammaticChanges: widget.cascadeProgrammaticChanges,
                ),
              ),
            ],
          ),
          if (_isSaving)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black26,
                  child: Center(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 40,
                              height: 40,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              sdkTr('Saving...'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkflowHeader extends StatelessWidget {
  const _WorkflowHeader({
    required this.meta,
    required this.documentData,
    required this.loading,
    this.translate,
    required this.onShowActions,
    required this.showActions,
  });

  final DocTypeMeta meta;
  final Map<String, dynamic> documentData;
  final bool loading;
  final String Function(String)? translate;
  final VoidCallback onShowActions;
  final bool showActions;

  @override
  Widget build(BuildContext context) {
    final stateField = meta.workflowStateField;
    final currentState = stateField != null
        ? documentData[stateField]?.toString()
        : null;
    final stateLabel = currentState?.isNotEmpty == true ? currentState! : '—';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border(bottom: BorderSide(color: Colors.blue.shade200)),
      ),
      child: Row(
        children: [
          Text(
            translate != null ? translate!('Status') : 'Status',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.blue.shade900,
            ),
          ),
          const SizedBox(width: 8),
          Chip(
            label: Text(
              stateLabel,
              style: TextStyle(fontSize: 12, color: Colors.blue.shade900),
            ),
            backgroundColor: Colors.blue.shade100,
          ),
          const Spacer(),
          if (loading)
            const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (showActions)
            TextButton.icon(
              onPressed: onShowActions,
              icon: const Icon(Icons.playlist_play),
              label: Text(
                translate != null ? translate!('Actions') : 'Actions',
              ),
            ),
        ],
      ),
    );
  }
}
