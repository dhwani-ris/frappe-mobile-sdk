import 'dart:async';
import '../models/doc_field.dart';
import '../models/doc_type_meta.dart';
import '../constants/field_types.dart';
import '../database/entities/link_option_entity.dart';
import 'link_option_service.dart';

/// Progress event for link option loading.
class LinkLoadProgress {
  final bool loading;
  final String? message;

  const LinkLoadProgress({required this.loading, this.message});
}

/// Coordinates link field option fetching with dependency-aware sequencing.
/// - Independent fields: prefetch on form load.
/// - Dependent fields: fetch only when parent value changes, in topological order.
/// - Broadcasts progress for non-blocking UI feedback.
class LinkFieldCoordinator {
  final DocTypeMeta meta;
  final LinkOptionService linkOptionService;
  final Map<String, dynamic> _formData = {};
  final StreamController<LinkLoadProgress> _progressController =
      StreamController<LinkLoadProgress>.broadcast();
  final Map<String, int> _fieldTier = {};
  final Map<String, List<DocField>> _childrenOf = {};
  final Map<String, List<String>> _parentsOf = {};
  final Map<String, List<LinkOptionEntity>> _resultsCache = {};
  final Map<String, Future<List<LinkOptionEntity>>> _inProgress = {};
  bool _prefetchStarted = false;
  static const int _maxConcurrent = 1; // Sequential for predictable ordering
  int _inFlight = 0;
  final List<_PendingRequest> _queue = [];
  bool _useCoordinator = true;

  LinkFieldCoordinator({
    required this.meta,
    required this.linkOptionService,
    bool useCoordinator = true,
  }) : _useCoordinator = useCoordinator {
    _buildDependencyGraph();
  }

  /// Whether the coordinator is active (can disable via feature flag).
  bool get useCoordinator => _useCoordinator;

  /// Stream of loading progress for UI indicator.
  Stream<LinkLoadProgress> get progressStream => _progressController.stream;

  void _buildDependencyGraph() {
    final linkFields = meta.fields
        .where(
          (f) =>
              f.fieldtype == FieldTypes.link &&
              f.fieldname != null &&
              f.options != null &&
              f.options!.isNotEmpty &&
              !f.hidden,
        )
        .toList();

    for (final f in linkFields) {
      final parents =
          LinkOptionService.getDependentFieldNames(f.linkFilters);
      if (f.fieldname != null) {
        _parentsOf[f.fieldname!] = parents;
        for (final p in parents) {
          _childrenOf.putIfAbsent(p, () => []).add(f);
        }
      }
    }

    final tierMap = <String, int>{};
    int computeTier(String fieldname, Set<String> visiting) {
      if (tierMap.containsKey(fieldname)) return tierMap[fieldname]!;
      if (visiting.contains(fieldname)) {
        return 0;
      }
      visiting.add(fieldname);
      try {
        final parents = _parentsOf[fieldname] ?? [];
        final linkFieldNames = linkFields
            .where((f) => f.fieldname != null)
            .map((f) => f.fieldname!)
            .toSet();
        if (parents.isEmpty) {
          tierMap[fieldname] = 0;
          return 0;
        }
        int maxParentTier = 0;
        for (final p in parents) {
          if (!linkFieldNames.contains(p)) {
            continue;
          }
          final pt = computeTier(p, visiting);
          if (pt > maxParentTier) maxParentTier = pt;
        }
        tierMap[fieldname] = maxParentTier + 1;
        return maxParentTier + 1;
      } finally {
        visiting.remove(fieldname);
      }
    }

    for (final f in linkFields) {
      if (f.fieldname != null) {
        _fieldTier[f.fieldname!] = computeTier(f.fieldname!, {});
      }
    }
  }

  /// Link fields with no eval:doc.* in linkFilters (tier 0).
  List<DocField> getIndependentLinkFields() {
    return meta.fields
        .where(
          (f) =>
              f.fieldtype == FieldTypes.link &&
              f.fieldname != null &&
              f.options != null &&
              f.options!.isNotEmpty &&
              !f.hidden &&
              (_fieldTier[f.fieldname] ?? 0) == 0,
        )
        .toList();
  }

  /// Link fields with eval:doc.* in linkFilters (tier >= 1).
  List<DocField> getDependentLinkFields() {
    return meta.fields
        .where(
          (f) =>
              f.fieldtype == FieldTypes.link &&
              f.fieldname != null &&
              f.options != null &&
              f.options!.isNotEmpty &&
              !f.hidden &&
              (_fieldTier[f.fieldname] ?? 0) > 0,
        )
        .toList();
  }

  /// All parents have non-empty values in formData.
  bool canFetchNow(DocField field, Map<String, dynamic> formData) {
    final parents = _parentsOf[field.fieldname] ?? [];
    for (final p in parents) {
      final val = formData[p];
      if (val == null ||
          (val is String && val.trim().isEmpty) ||
          val.toString().trim().isEmpty) {
        return false;
      }
    }
    return true;
  }

  int getTier(DocField field) {
    return field.fieldname != null
        ? (_fieldTier[field.fieldname!] ?? 0)
        : 0;
  }

  List<DocField> getChildrenOf(String parentFieldname) {
    return _childrenOf[parentFieldname] ?? [];
  }

  /// Update form data; used to determine when dependent fields can fetch.
  void updateFormData(Map<String, dynamic> formData) {
    _formData.clear();
    _formData.addAll(formData);
  }

  void _emitProgress(bool loading, [String? message]) {
    if (!_progressController.isClosed) {
      _progressController.add(LinkLoadProgress(loading: loading, message: message));
    }
  }

  String _cacheKey(String doctype, List<List<dynamic>>? filters) {
    if (filters == null || filters.isEmpty) return doctype;
    return '$doctype|${filters.hashCode}';
  }

  /// Enqueue and execute fetch; returns when complete.
  /// Coordinator sequences requests and emits progress.
  /// Deduplicates by cache key - same doctype+filters returns same future.
  Future<List<LinkOptionEntity>> requestFetch(
    String doctype, {
    List<List<dynamic>>? filters,
    String? fieldLabel,
    String? fieldname,
  }) async {
    final ck = _cacheKey(doctype, filters);
    if (_resultsCache.containsKey(ck)) {
      return Future.value(_resultsCache[ck]!);
    }
    if (_inProgress.containsKey(ck)) {
      return _inProgress[ck]!;
    }
    final completer = Completer<List<LinkOptionEntity>>();
    final future = completer.future;
    _inProgress[ck] = future;

    final req = _PendingRequest(
      doctype: doctype,
      filters: filters,
      fieldLabel: fieldLabel,
      fieldname: fieldname,
      completer: completer,
    );
    _queue.add(req);
    _processQueue();

    future.whenComplete(() {
      _inProgress.remove(ck);
    });
    return future;
  }

  Future<void> _processQueue() async {
    while (_inFlight < _maxConcurrent && _queue.isNotEmpty) {
      final req = _queue.removeAt(0);
      _inFlight++;
      _emitProgress(true, 'Loading ${req.fieldLabel ?? req.doctype}...');

      try {
        final options = await linkOptionService.getLinkOptions(
          req.doctype,
          filters: req.filters,
        );
        final ck = _cacheKey(req.doctype, req.filters);
        _resultsCache[ck] = options;
        if (!req.completer.isCompleted) {
          req.completer.complete(options);
        }
      } catch (e) {
        if (!req.completer.isCompleted) {
          req.completer.complete([]);
        }
      } finally {
        _inFlight--;
        if (_inFlight == 0 && _queue.isEmpty) {
          _emitProgress(false);
        }
        if (_queue.isNotEmpty) {
          _processQueue();
        }
      }
    }
  }

  /// Register a field for coordinated loading. Coordinator will fetch when ready
  /// and invoke [onOptions] with the result.
  void registerField(
    DocField field,
    Map<String, dynamic> formData,
    void Function(List<LinkOptionEntity>) onOptions,
  ) {
    if (!_useCoordinator || field.fieldname == null || field.options == null) {
      return;
    }
    updateFormData(formData);

    final tier = getTier(field);
    if (tier > 0 && !canFetchNow(field, formData)) {
      return;
    }

    final filters = LinkOptionService.parseLinkFilters(field.linkFilters, formData);
    if (tier > 0 && filters == null) {
      return;
    }

    final ck = _cacheKey(field.options!, filters);
    if (_resultsCache.containsKey(ck)) {
      onOptions(_resultsCache[ck]!);
      return;
    }

    requestFetch(
      field.options!,
      filters: filters,
      fieldLabel: field.displayLabel,
      fieldname: field.fieldname,
    ).then(onOptions);
  }

  /// Prefetch independent fields on form load, then sequenced dependent fields
  /// that have satisfied parents from initialData.
  void prefetchInitial(Map<String, dynamic>? initialData) {
    if (_prefetchStarted || !_useCoordinator) return;
    _prefetchStarted = true;
    updateFormData(initialData ?? {});

    final independent = getIndependentLinkFields();
    final dependent = getDependentLinkFields();
    final sortedDependent = List<DocField>.from(dependent)
      ..sort((a, b) => getTier(a).compareTo(getTier(b)));

    for (final field in independent) {
      if (field.fieldname == null || field.options == null) continue;
      requestFetch(
        field.options!,
        filters: LinkOptionService.parseLinkFilters(field.linkFilters, _formData),
        fieldLabel: field.displayLabel,
        fieldname: field.fieldname,
      );
    }

    for (final field in sortedDependent) {
      if (field.fieldname == null || field.options == null) continue;
      if (!canFetchNow(field, _formData)) continue;
      final filters = LinkOptionService.parseLinkFilters(field.linkFilters, _formData);
      if (filters == null) continue;
      requestFetch(
        field.options!,
        filters: filters,
        fieldLabel: field.displayLabel,
        fieldname: field.fieldname,
      );
    }
  }

  void dispose() {
    _progressController.close();
  }
}

class _PendingRequest {
  final String doctype;
  final List<List<dynamic>>? filters;
  final String? fieldLabel;
  final String? fieldname;
  final Completer<List<LinkOptionEntity>> completer;

  _PendingRequest({
    required this.doctype,
    this.filters,
    this.fieldLabel,
    this.fieldname,
    required this.completer,
  });
}
