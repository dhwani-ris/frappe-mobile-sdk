import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import '../../models/doc_field.dart';
import '../../models/doc_type_meta.dart';
import '../../utils/depends_on_evaluator.dart';
import 'dependency_graph.dart';
import 'field_ui_state.dart';
import 'form_validators.dart';
import '../widgets/form_builder.dart' show FieldChangeHandler;

/// Origin of a value mutation. The in-pipeline reaction hook fires only for
/// `user`/`programmatic`; `reaction`/`system` never re-trigger it (loop-free).
enum ChangeSource { user, programmatic, reaction, system }

/// A tab in the form (derived from Tab Break fields): its label + the data
/// fieldnames it contains. Exposed so the app can drive tab navigation.
class FormTabInfo {
  final String label;
  final List<String> fieldNames;
  const FormTabInfo(this.label, this.fieldNames);
}

/// Semantic field lifecycle (not raw widget mount): a field becoming
/// present/absent (reported by the widget, which alone knows the rendered state
/// incl. enclosing Section/Tab Break visibility) or gaining/losing focus.
enum FieldLifecycleKind { mounted, unmounted, focusGained, focusLost }

class FieldLifecycleEvent {
  final String field;
  final FieldLifecycleKind kind;
  const FieldLifecycleEvent(this.field, this.kind);
}

/// Framework-agnostic form state controller. Single source of truth for values.
/// See the form state-management design spec.
class FormController extends ChangeNotifier {
  FormController({
    required DocTypeMeta meta,
    Map<String, dynamic>? initialData,
    DateTime Function()? now,
  }) : _meta = meta,
       _now = now ?? DateTime.now {
    _graph = DependencyGraph.build(meta);
    assert(() {
      _graph.assertNoValueCycles();
      return true;
    }());
    _seedDefaults(initialData);
    _baseline = Map<String, dynamic>.from(_rawValues);
  }

  DocTypeMeta _meta; // mutable: reset({meta}) rebuilds against a new schema
  final DateTime Function() _now;
  late DependencyGraph _graph;

  final Map<String, dynamic> _rawValues = {};
  final Map<String, ValueNotifier<dynamic>> _valueNotifiers = {};
  final Map<String, ValueNotifier<FieldUiState>> _uiNotifiers = {};
  late Map<String, dynamic> _baseline;

  // ── construction helpers ────────────────────────────────────────────────
  void _seedDefaults(Map<String, dynamic>? initialData) {
    for (final f in _meta.fields) {
      final name = f.fieldname;
      if (name == null || name.isEmpty) continue;
      if (initialData != null && initialData.containsKey(name)) {
        _rawValues[name] = initialData[name];
        continue;
      }
      final def = f.defaultValue;
      if (def != null &&
          f.fieldtype == 'Date' &&
          def.toLowerCase() == 'today') {
        final d = _now();
        _rawValues[name] =
            '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      } else {
        _rawValues[name] = def;
      }
    }
  }

  bool _isDynamic(DocField f) =>
      (f.dependsOn?.isNotEmpty ?? false) ||
      (f.mandatoryDependsOn?.isNotEmpty ?? false) ||
      (f.readOnlyDependsOn?.isNotEmpty ?? false);

  // ── read / write ──────────────────────────────────────────────────────────
  dynamic getValue(String field) => _rawValues[field];
  Map<String, dynamic> get values => Map<String, dynamic>.from(_rawValues);

  ValueNotifier<dynamic> valueOf(String field) => _valueNotifiers.putIfAbsent(
    field,
    () => ValueNotifier(_rawValues[field]),
  );

  ValueNotifier<FieldUiState> uiStateOf(String field) => _uiNotifiers
      .putIfAbsent(field, () => ValueNotifier(_computeUiState(field)));

  /// Origin of the field's most recent value mutation, or null if never set.
  /// The reactive widget layer uses this to avoid clobbering an in-progress
  /// user edit on rebuild (the user's keystroke already lives in the field).
  ChangeSource? lastSourceOf(String field) => _lastSource[field];

  // ── batching / flush state ──────────────────────────────────────────────
  bool _batching = false;
  bool _flushing = false;
  bool _tracing = false;
  final Set<String> _pendingChanged =
      {}; // fields whose value changed, awaiting drain
  final Map<String, ChangeSource> _lastSource =
      {}; // origin of each pending change

  /// Enable a structured per-flush trace (changed/affected fields + timing) via
  /// debugPrint. Debug aid only; zero cost when off.
  void enableDebugTracing() => _tracing = true;

  /// Optional: resolves a linked doc for fetch_from. Wired by the widget layer.
  Future<Map<String, dynamic>?> Function(String doctype, String name)?
  fetchLinkedDocument;

  /// In-pipeline app logic (the onFieldChange successor). Called during the flush
  /// for each user/programmatic-changed field, in meta order; returned patches
  /// re-enter the same fixed-point as ChangeSource.reaction (so they never
  /// re-trigger a reaction — loop-free; last-writer-wins on conflict).
  FieldChangeHandler? onFieldReaction;

  /// Coalesce many mutations into ONE propagation + ONE notification round.
  void batch(void Function() mutations) {
    final wasBatching = _batching;
    _batching = true;
    try {
      mutations();
    } finally {
      _batching = wasBatching;
      if (!_batching) _flush();
    }
  }

  void setValue(
    String field,
    dynamic value, {
    ChangeSource source = ChangeSource.programmatic,
    @Deprecated('use source: ChangeSource.user') bool fromUser = false,
  }) {
    _lastSource[field] = fromUser ? ChangeSource.user : source;
    _applyValue(field, value);
    // Synchronous flush per top-level setValue. Inside batch(), or re-entrantly
    // during a flush, just accumulate — the active/next flush drains _pendingChanged.
    if (_batching || _flushing) return;
    _flush();
  }

  void _applyValue(String field, dynamic value) {
    if (_rawValues[field] == value) {
      return; // equality short-circuit: breaks FB echo loop
    }
    _rawValues[field] = value;
    _pendingChanged.add(field);
  }

  /// Declaration index of [field] in the meta (reaction ordering). Unknown -> last.
  int _metaIndex(String field) {
    for (var i = 0; i < _meta.fields.length; i++) {
      if (_meta.fields[i].fieldname == field) return i;
    }
    return 1 << 30;
  }

  /// Single fixed-point loop. EVERY value mutation — typed, link-cleared,
  /// fetch-patched, or cleared-because-hidden — feeds the same worklist, so the
  /// loop runs until neither values nor visibility change. This makes the
  /// transitive visibility cascade (A->B->C->...->N) correct: a field cleared
  /// because it became hidden is re-enqueued and drives the next level's recompute.
  void _flush() {
    if (_flushing) return; // re-entrant writes accumulate in _pendingChanged
    _flushing = true;
    final Set<String> traceSeed = _tracing ? {..._pendingChanged} : const {};
    final Stopwatch? traceSw = _tracing ? (Stopwatch()..start()) : null;
    final touched = <String>{};
    final cap = (_meta.fields.length + 1) * 4; // backstop vs non-convergence
    var iterations = 0;

    try {
      while (_pendingChanged.isNotEmpty) {
        // (0) In-pipeline reactions for THIS round. Fire for every changed field
        //     whose source is not `reaction`, so user/programmatic AND system
        //     (fetch_from, link-clear, clear-on-hide) recompute their dependents.
        //     Patches re-enter as ChangeSource.reaction and are excluded here, so
        //     a reaction never re-fires on its own output (loop-free); the
        //     iteration cap below backstops a pathological reaction<->clear cycle.
        if (onFieldReaction != null) {
          final reactSeed =
              _pendingChanged
                  .where((f) => _lastSource[f] != ChangeSource.reaction)
                  .toList()
                ..sort((a, b) => _metaIndex(a).compareTo(_metaIndex(b)));
          for (final f in reactSeed) {
            final patches = onFieldReaction!(
              f,
              _rawValues[f],
              values,
              source: _lastSource[f] ?? ChangeSource.user,
            );
            if (patches != null) {
              patches.forEach((k, v) {
                _lastSource[k] = ChangeSource.reaction;
                _applyValue(k, v);
              });
            }
          }
        }

        final worklist = <String>[..._pendingChanged];
        _pendingChanged.clear();
        while (worklist.isNotEmpty) {
          if (iterations++ > cap) {
            assert(
              false,
              'FormController: propagation exceeded cap ($cap) — likely a '
              'reaction<->clear oscillation; aborting.',
            );
            debugPrint(
              'FormController: propagation exceeded cap ($cap); aborting.',
            );
            worklist.clear();
            _pendingChanged.clear();
            break;
          }
          final changed = worklist.removeAt(0);
          touched.add(changed);

          // (a) link-filter clearing — each cleared field is a value mutation.
          for (final tgt in _graph.linkClearsOf(changed)) {
            if (_rawValues[tgt] != null) {
              _rawValues[tgt] = null;
              _lastSource[tgt] = ChangeSource.system;
              touched.add(tgt);
              worklist.add(tgt);
            }
          }

          // (b) fetch_from (async; the patched target re-enters via setValue).
          _runFetchFrom(changed);

          // (c) recompute UI state of direct dependents; a visible->false flip
          //     clears the field's value AND re-enqueues it (transitive cascade).
          for (final f in _graph.affectedBy(changed)) {
            final next = _computeUiState(f);
            final notifier = _uiNotifiers[f];
            if (notifier != null && notifier.value != next) {
              notifier.value = next;
              touched.add(f);
            }
            if (!next.visible && _rawValues[f] != null) {
              _rawValues[f] = null; // clear-on-hide (matches current behavior)
              _lastSource[f] = ChangeSource.system;
              touched.add(f);
              worklist.add(f); // <-- re-enters the worklist: next level
            }
          }
        }
      }
    } finally {
      _flushing = false;
    }

    // Push value notifiers for everything that changed, recompute dirty, notify once.
    for (final t in touched) {
      _valueNotifiers[t]?.value = _rawValues[t];
    }
    if (_tracing) {
      traceSw!.stop();
      final affected = <String>{
        for (final s in traceSeed) ..._graph.affectedBy(s),
      };
      debugPrint(
        '[form] changed=$traceSeed affected=$affected touched=$touched '
        '· controller ${(traceSw.elapsedMicroseconds / 1000).toStringAsFixed(2)}ms',
      );
    }
    _submitData.value =
        buildSubmitData(); // before dirty -> bridge order data->dirty
    _recomputeDirty();
    notifyListeners();
  }

  // ── dirty / valid state ─────────────────────────────────────────────────
  final ValueNotifier<bool> _isDirty = ValueNotifier(false);
  final ValueNotifier<bool> _isValid = ValueNotifier(true);
  ValueListenable<bool> get isDirty => _isDirty;
  ValueListenable<bool> get isValid => _isValid;

  /// Reactive submit payload (== buildSubmitData()), updated once per flush.
  /// `value` is a fresh copy the caller may mutate freely.
  late final ValueNotifier<Map<String, dynamic>> _submitData =
      ValueNotifier<Map<String, dynamic>>(buildSubmitData());
  ValueListenable<Map<String, dynamic>> get submitData => _submitData;

  /// Rebaseline after a successful save/sync so `1 -> 2 -> 1` ends not-dirty.
  void markPristine() {
    _baseline = Map<String, dynamic>.from(_rawValues);
    _isDirty.value = false;
  }

  /// isDirty = current values differ from baseline (companion keys excluded).
  void _recomputeDirty() {
    bool dirty = false;
    final keys = {..._baseline.keys, ..._rawValues.keys};
    for (final k in keys) {
      if (k.endsWith('__is_local')) continue; // companion key, not user data
      if (_baseline[k] != _rawValues[k]) {
        dirty = true;
        break;
      }
    }
    _isDirty.value = dirty;
  }

  /// Run fetch_from for every field already holding a value (seeded from
  /// initialData) that is the SOURCE of a fetch_from edge. Call once after
  /// [fetchLinkedDocument] is wired so an edit-form prefilled with a Link
  /// populates its fetch targets (e.g. patient_name/doctor from patient).
  /// Idempotent: re-fetching writes the same values via ChangeSource.system.
  void runInitialFetchFrom() {
    if (fetchLinkedDocument == null) return;
    for (final f in _meta.fields) {
      final name = f.fieldname;
      if (name == null || name.isEmpty) continue;
      final v = _rawValues[name];
      if (v == null || v.toString().trim().isEmpty) continue;
      if (_graph.fetchTargetsOf(name).isEmpty) continue;
      _runFetchFrom(name);
    }
  }

  void _runFetchFrom(String changed) {
    final targets = _graph.fetchTargetsOf(changed);
    if (targets.isEmpty || fetchLinkedDocument == null) return;
    final linkField = _meta.fields.firstWhere(
      (f) => f.fieldname == changed,
      orElse: () => DocField(fieldtype: '_missing_'),
    );
    final linkedDoctype = linkField.options;
    final docName = _rawValues[changed]?.toString().trim();
    if (linkedDoctype == null || docName == null || docName.isEmpty) return;
    final dispatchedFor = docName; // capture for stale-response guard

    fetchLinkedDocument!(linkedDoctype, dispatchedFor).then((linked) {
      if (linked == null) return;
      // Stale-response guard (latest-wins): ignore if the source changed since dispatch.
      if (_rawValues[changed]?.toString().trim() != dispatchedFor) return;
      batch(() {
        for (final tgtName in targets) {
          final tgt = _meta.fields.firstWhere(
            (f) => f.fieldname == tgtName,
            orElse: () => DocField(fieldtype: '_missing_'),
          );
          final src = tgt.fetchFrom!.split('.')[1].trim();
          if (linked.containsKey(src)) {
            setValue(
              tgtName,
              linked[src]?.toString(),
              source: ChangeSource.system,
            );
          }
        }
      });
    });
  }

  FieldUiState _computeUiState(String field) {
    final f = _meta.fields.firstWhere(
      (e) => e.fieldname == field,
      orElse: () => DocField(fieldtype: '_missing_'),
    );
    if (!_isDynamic(f) && !f.reqd && !f.readOnly) return FieldUiState.editable;
    // `depends_on` keeps the `onError: true` default — an unparseable
    // expression SHOWS the field rather than silently hiding data.
    final visible = DependsOnEvaluator.evaluate(f.dependsOn, _rawValues);
    // The other two must invert it: erring towards required blocks the save
    // with nothing the user can do about it, and erring towards locked makes
    // the field permanently uneditable. FormBuilder's `_isFieldRequired` /
    // `_isFieldReadOnly` already pass `false`; reactive mode must agree with
    // them or the same field disagrees between the two engines.
    final required =
        f.reqd ||
        DependsOnEvaluator.evaluate2(
          f.mandatoryDependsOn,
          _rawValues,
          false,
          onError: false,
        );
    final readOnly =
        f.readOnly ||
        DependsOnEvaluator.evaluate2(
          f.readOnlyDependsOn,
          _rawValues,
          false,
          onError: false,
        );
    return FieldUiState(
      visible: visible,
      required: required,
      readOnly: readOnly,
    );
  }

  // ── validation ──────────────────────────────────────────────────────────
  final Map<String, List<FieldValidator>> _fieldValidators = {};
  final Map<String, List<AsyncFieldValidator>> _asyncValidators = {};
  final List<CrossFieldValidator> _crossValidators = [];
  final Map<String, String?> _errors = {};

  /// First-invalid field after a validate() pass (for focus). Null if valid.
  String? firstInvalidField;

  void addFieldValidator(String field, FieldValidator v) =>
      (_fieldValidators[field] ??= []).add(v);
  void addAsyncFieldValidator(String field, AsyncFieldValidator v) =>
      (_asyncValidators[field] ??= []).add(v);
  void addCrossFieldValidator(CrossFieldValidator v) => _crossValidators.add(v);

  final Map<String, ValueNotifier<String?>> _errorNotifiers = {};

  String? errorOf(String field) => _errors[field];

  /// Reactive per-field error (updated on each validate*/validateField). Null = valid.
  ValueListenable<String?> errorListenableOf(String field) => _errorNotifiers
      .putIfAbsent(field, () => ValueNotifier<String?>(_errors[field]));

  /// Field→message for everything that failed the last validate*. Superset of [firstInvalidField].
  Map<String, String> get invalidFields => {
    for (final e in _errors.entries)
      if (e.value != null) e.key: e.value!,
  };

  /// Validate a single field (e.g. on blur); updates its error listenable + isValid.
  bool validateField(String field) {
    final e = _validateField(field);
    if (e == null) {
      _errors.remove(field);
    } else {
      _errors[field] = e;
    }
    _errorNotifiers[field]?.value = e;
    _isValid.value = _errors.values.every((x) => x == null);
    notifyListeners();
    return e == null;
  }

  /// Priority per field (first non-null wins): reqd -> sync field validators.
  /// Async runs only in validateAsync(); cross-field runs in validate().
  String? _validateField(String field) {
    final f = _meta.fields.firstWhere(
      (e) => e.fieldname == field,
      orElse: () => DocField(fieldtype: '_missing_'),
    );
    if (!uiStateOf(field).value.visible) {
      return null; // hidden fields don't validate
    }
    final v = _rawValues[field];
    final ui = uiStateOf(field).value;
    // "Missing" semantics are shared with the legacy FrappeFormBuilder
    // mandatory sweep and must agree with it, or reactive and legacy mode
    // accept different payloads. Trim-aware: a whitespace-only string is
    // missing (it is also blank server-side). `0` / `false` stay PRESENT
    // (Frappe treats them as set), an empty List stays missing, and any other
    // type keeps the original `toString().isEmpty` probe.
    final missing =
        v == null ||
        (v is List && v.isEmpty) ||
        (v is String && v.trim().isEmpty) ||
        (v is! List && v is! String && v.toString().isEmpty);
    if ((f.reqd || ui.required) && missing) {
      return '${f.label ?? field} is required';
    }
    for (final validator in _fieldValidators[field] ?? const []) {
      final e = validator(v, _rawValues);
      if (e != null) return e;
    }
    return null;
  }

  bool validate() {
    _errors.clear();
    firstInvalidField = null;
    for (final f in _meta.fields) {
      final name = f.fieldname;
      if (name == null || name.isEmpty) continue;
      final e = _validateField(name);
      if (e != null) {
        _errors[name] = e;
        firstInvalidField ??= name;
      }
    }
    for (final cross in _crossValidators) {
      final res = cross(_rawValues);
      if (res != null) {
        res.forEach((k, v) {
          if (v != null) {
            _errors[k] = v;
            firstInvalidField ??= k;
          }
        });
      }
    }
    for (final f in _meta.fields) {
      final n = f.fieldname;
      if (n != null) _errorNotifiers[n]?.value = _errors[n];
    }
    final ok = _errors.values.every((e) => e == null);
    _isValid.value = ok;
    notifyListeners();
    return ok;
  }

  Future<bool> validateAsync() async {
    final syncOk = validate();
    var ok = syncOk;
    for (final entry in _asyncValidators.entries) {
      final name = entry.key;
      if (_errors[name] != null) continue; // sync error already shown
      if (!uiStateOf(name).value.visible) continue;
      for (final v in entry.value) {
        final dispatched = _rawValues[name]; // capture value at dispatch
        final e = await v(dispatched, _rawValues);
        if (_rawValues[name] != dispatched) {
          break; // stale: value changed -> discard
        }
        if (e != null) {
          _errors[name] = e;
          _errorNotifiers[name]?.value = e;
          firstInvalidField ??= name;
          ok = false;
          break;
        }
      }
    }
    _isValid.value = ok;
    notifyListeners();
    return ok;
  }

  // ── submit payload ──────────────────────────────────────────────────────
  /// Mirrors the current _handleSubmit payload assembly: fill visible data
  /// fields from value/initialData/default/empty, then drop fields hidden by
  /// their own depends_on OR by an enclosing Section/Tab break's depends_on.
  Map<String, dynamic> buildSubmitData() {
    final complete = <String, dynamic>{};
    for (final f in _meta.fields) {
      final name = f.fieldname;
      if (name == null || f.hidden || !f.isDataField) continue;
      complete[name] =
          _rawValues[name] ??
          (f.fieldtype == 'Check'
              ? 0
              : (f.fieldtype == 'Table' || f.fieldtype == 'Table MultiSelect')
              ? <dynamic>[]
              : (f.defaultValue ?? ''));
    }
    // also carry non-null companion/extra keys present in raw values
    _rawValues.forEach((k, v) {
      if (v != null) complete[k] = v;
    });

    // drop hidden-by-own-depends_on and hidden-by-container
    final hiddenByContainer = <String>{};
    String? secDeps, tabDeps;
    for (final f in _meta.fields) {
      if (f.fieldtype == 'Tab Break') {
        tabDeps = f.dependsOn?.isNotEmpty == true ? f.dependsOn : null;
        secDeps = null;
        continue;
      }
      if (f.fieldtype == 'Section Break') {
        secDeps = f.dependsOn?.isNotEmpty == true ? f.dependsOn : null;
        continue;
      }
      if (f.fieldtype == 'Column Break' || f.fieldname == null) continue;
      final tabHidden =
          tabDeps != null && !DependsOnEvaluator.evaluate(tabDeps, complete);
      final secHidden =
          secDeps != null && !DependsOnEvaluator.evaluate(secDeps, complete);
      if (tabHidden || secHidden) hiddenByContainer.add(f.fieldname!);
    }
    complete.removeWhere((name, _) {
      if (hiddenByContainer.contains(name)) return true;
      final f = _meta.fields.firstWhere(
        (e) => e.fieldname == name,
        orElse: () => DocField(fieldtype: '_missing_'),
      );
      if (f.fieldtype == '_missing_') return false;
      if (f.dependsOn == null || f.dependsOn!.isEmpty) return false;
      return !DependsOnEvaluator.evaluate(f.dependsOn, complete);
    });
    return complete;
  }

  // ── focus & lifecycle ───────────────────────────────────────────────────
  final Map<String, FocusNode> _focusNodes = {};
  final ValueNotifier<String?> _focusedField = ValueNotifier(null);
  ValueListenable<String?> get focusedField => _focusedField;

  final StreamController<FieldLifecycleEvent> _lifecycle =
      StreamController<FieldLifecycleEvent>.broadcast();
  Stream<FieldLifecycleEvent> get fieldLifecycle => _lifecycle.stream;

  // Safe after dispose: the widget's field hosts may report unmount during their
  // own teardown, which can run after this controller is disposed.
  void _emitLifecycle(FieldLifecycleEvent e) {
    if (!_lifecycle.isClosed) _lifecycle.add(e);
  }

  /// Called by the widget when a field is actually built/removed (it alone knows
  /// the true rendered state, incl. enclosing Section/Tab Break visibility).
  void reportFieldMounted(String field) =>
      _emitLifecycle(FieldLifecycleEvent(field, FieldLifecycleKind.mounted));
  void reportFieldUnmounted(String field) =>
      _emitLifecycle(FieldLifecycleEvent(field, FieldLifecycleKind.unmounted));

  FocusNode focusNodeOf(String field) => _focusNodes.putIfAbsent(field, () {
    final node = FocusNode(debugLabel: field);
    node.addListener(() {
      if (node.hasFocus) {
        _focusedField.value = field;
        _emitLifecycle(
          FieldLifecycleEvent(field, FieldLifecycleKind.focusGained),
        );
      } else {
        _emitLifecycle(
          FieldLifecycleEvent(field, FieldLifecycleKind.focusLost),
        );
      }
    });
    return node;
  });

  void requestFocus(String field) => focusNodeOf(field).requestFocus();

  // ── field render contexts (scroll-into-view) ──────────────────────────────
  // The field hosts register their BuildContext while mounted+visible, so a
  // field can be scrolled into view by name regardless of its type. This is
  // more reliable than focus-based scrolling (FocusNode.requestFocus only
  // scrolls editable text into view, not dropdowns / multiselects) and than
  // FormFieldState.hasError tree-walks (app-level validation errors — cross
  // field, required-multiselect — never set FormFieldState.hasError).
  final Map<String, BuildContext> _fieldContexts = {};

  void registerFieldContext(String field, BuildContext context) =>
      _fieldContexts[field] = context;

  void unregisterFieldContext(String field) => _fieldContexts.remove(field);

  /// Scrolls the first of [fields] (in iteration order) that is currently
  /// mounted and visible into view, and returns it; null if none had a live
  /// render context. [alignment] 0.1 leaves room for a sticky header/banner.
  String? scrollToFirstField(
    Iterable<String> fields, {
    double alignment = 0.1,
  }) {
    for (final f in fields) {
      final ctx = _fieldContexts[f];
      if (ctx == null || !ctx.mounted) continue;
      final ro = ctx.findRenderObject();
      if (ro == null || !ro.attached) continue;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
        alignment: alignment,
      );
      return f;
    }
    return null;
  }

  /// Convenience: scroll a single [field] into view. Returns true if it had a
  /// live render context and was scrolled to.
  bool scrollToField(String field, {double alignment = 0.1}) =>
      scrollToFirstField([field], alignment: alignment) != null;

  // ── view intents: tab / section navigation (no BuildContext) ──────────────
  late final List<FormTabInfo> _tabs = _computeTabs();
  List<FormTabInfo> get tabs => _tabs;
  final ValueNotifier<int> _activeTab = ValueNotifier(0);
  ValueListenable<int> get activeTab => _activeTab;
  final StreamController<String> _scrollRequests =
      StreamController<String>.broadcast();
  Stream<String> get scrollRequests => _scrollRequests.stream;

  List<FormTabInfo> _computeTabs() {
    final tabs = <FormTabInfo>[];
    var label = 'Details';
    var fields = <String>[];
    void flush() => tabs.add(FormTabInfo(label, List.of(fields)));
    for (final f in _meta.fields) {
      if (f.fieldtype == 'Tab Break') {
        flush();
        label = f.label ?? 'Tab ${tabs.length + 1}';
        fields = [];
      } else if (f.fieldname != null && f.isDataField) {
        fields.add(f.fieldname!);
      }
    }
    flush();
    return tabs;
  }

  /// Index of the tab containing [field] (0 if not found).
  int tabIndexOf(String field) {
    for (var i = 0; i < _tabs.length; i++) {
      if (_tabs[i].fieldNames.contains(field)) return i;
    }
    return 0;
  }

  /// Switch the active tab. No-op when already on [index] or out of range.
  void goToTab(int index) {
    if (index == _activeTab.value) return;
    if (index < 0 || index >= _tabs.length) return;
    _activeTab.value = index;
  }

  /// Ask the view to scroll [field] into view (the widget performs the scroll).
  void requestScrollToField(String field) => _scrollRequests.add(field);

  /// Rebuilds the graph + reseeds values on a meta/initialData change, REUSING
  /// existing value/uiState notifiers for surviving fields so app listeners survive.
  void reset({DocTypeMeta? meta, Map<String, dynamic>? initialData}) {
    final newMeta = meta ?? _meta;
    _meta = newMeta;
    _graph = DependencyGraph.build(newMeta);
    final surviving = newMeta.fields
        .map((f) => f.fieldname)
        .whereType<String>()
        .toSet();
    _rawValues.removeWhere(
      (k, _) => !surviving.contains(k) && !k.endsWith('__is_local'),
    );
    // dispose notifiers for removed fields
    for (final k in _valueNotifiers.keys.toList()) {
      if (!surviving.contains(k)) _valueNotifiers.remove(k)!.dispose();
    }
    for (final k in _uiNotifiers.keys.toList()) {
      if (!surviving.contains(k)) _uiNotifiers.remove(k)!.dispose();
    }
    _seedDefaults(initialData); // re-seed (overwrites surviving values)
    for (final e in _valueNotifiers.entries) {
      e.value.value = _rawValues[e.key];
    }
    for (final e in _uiNotifiers.entries) {
      e.value.value = _computeUiState(e.key);
    }
    // clear validation + dispose error notifiers / focus nodes for removed fields
    _errors.clear();
    for (final n in _errorNotifiers.values) {
      n.value = null;
    }
    for (final k in _errorNotifiers.keys.toList()) {
      if (!surviving.contains(k)) _errorNotifiers.remove(k)!.dispose();
    }
    // focus nodes were leaking on schema change — dispose removed ones here.
    for (final k in _focusNodes.keys.toList()) {
      if (!surviving.contains(k)) _focusNodes.remove(k)!.dispose();
    }
    firstInvalidField = null;
    _isValid.value = true;
    _activeTab.value = 0;
    _baseline = Map<String, dynamic>.from(_rawValues);
    _isDirty.value = false;
    _submitData.value = buildSubmitData();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final n in _valueNotifiers.values) {
      n.dispose();
    }
    for (final n in _uiNotifiers.values) {
      n.dispose();
    }
    for (final n in _errorNotifiers.values) {
      n.dispose();
    }
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    _focusedField.dispose();
    _isDirty.dispose();
    _isValid.dispose();
    _submitData.dispose();
    _activeTab.dispose();
    _scrollRequests.close();
    _lifecycle.close();
    super.dispose();
  }
}
