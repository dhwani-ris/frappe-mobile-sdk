import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/entities/link_option_entity.dart';
import '../models/doc_field.dart';
import '../models/link_filter_result.dart';
import '../models/meta_resolver.dart';
import '../query/unified_resolver.dart';
import '../utils/depends_on_evaluator.dart';

/// Fetches link field options via [UnifiedResolver] (DB-first + background API refresh).
///
/// The resolver handles both offline reads and online background refresh in a
/// single path. Per-form dedupe lives in [LinkFieldCoordinator._resultsCache],
/// which bounds the cost to one resolve call per (doctype, filters) per form open.
class LinkOptionService {
  final UnifiedResolver? _resolver;
  final MetaResolverFn? _metaResolver;
  final Stream<void>? _syncCompleteStream;

  /// Broadcasts after each closure-pull batch finishes. Wired from
  /// [FrappeSDK.syncComplete$]. Pickers and the [LinkFieldCoordinator]
  /// listen to this to invalidate stale empty caches and re-fetch
  /// options for fields whose target doctype just got fresh data.
  Stream<void>? get syncComplete$ => _syncCompleteStream;

  /// Primary constructor — inject a wired [UnifiedResolver].
  LinkOptionService(
    UnifiedResolver resolver,
    MetaResolverFn metaResolver, {
    Stream<void>? syncComplete$,
  }) : _resolver = resolver,
       _metaResolver = metaResolver,
       _syncCompleteStream = syncComplete$;

  /// Converts Frappe-shaped filter rows to the 3-tuple `[field, op, value]`
  /// shape that [UnifiedResolver.resolve] consumes. Frappe APIs hand back
  /// either 4-tuples (`[doctype, field, op, value]`) or already-3-tuples;
  /// rows of any other length are silently dropped (consistent with the
  /// pre-refactor inline behavior). The output type is always
  /// `List<List<dynamic>>` so both callers (`getLinkOptions` and
  /// `getLinkOptionsOffline`) get the same typed collection.
  static List<List<dynamic>> _toThreeTuples(List<List>? filters) {
    final out = <List<dynamic>>[];
    if (filters == null) return out;
    for (final f in filters) {
      if (f.length == 4) {
        out.add([f[1], f[2], f[3]]);
      } else if (f.length == 3) {
        out.add(List<dynamic>.from(f));
      }
    }
    return out;
  }

  /// Test / subclass constructor. Use when all methods are overridden and no
  /// resolver is needed (e.g. recording mocks in widget tests).
  LinkOptionService.withoutResolver()
    : _resolver = null,
      _metaResolver = null,
      _syncCompleteStream = null;

  /// Fetches link options via the resolver (DB-first + background refresh when online).
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    final resolver = _resolver;
    final metaResolver = _metaResolver;
    if (resolver == null || metaResolver == null) return const [];

    final normalizedFilters = _normalizeFiltersForDoctype(doctype, filters);
    final meta = await metaResolver(doctype);
    final titleField = meta.titleField;

    // Convert Frappe 4-tuple filters [doctype, field, op, value] → 3-tuples.
    final threeTuples = _toThreeTuples(normalizedFilters);

    final result = await resolver.resolve(
      doctype: doctype,
      filters: threeTuples,
      page: 0,
      pageSize: 5000,
    );

    return _rowsToEntities(result.rows, doctype, titleField);
  }

  /// Converts resolver rows to [LinkOptionEntity] list.
  List<LinkOptionEntity> _rowsToEntities(
    List<Map<String, Object?>> rows,
    String doctype,
    String? titleField,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <LinkOptionEntity>[];
    for (final row in rows) {
      // Offline rows from `docs__<doctype>` carry `server_name`; online rows
      // from `frappe.client.get_list` carry `name`. Mobile-created rows
      // pre-server-confirm carry only `mobile_uuid`. Try all three so the
      // mapping works in both modes.
      final name =
          (row['server_name'] as String?) ??
          (row['name'] as String?) ??
          (row['mobile_uuid'] as String?) ??
          '';
      if (name.isEmpty) continue;
      String? label;
      if (titleField != null && row[titleField] != null) {
        final s = row[titleField].toString().trim();
        if (s.isNotEmpty) label = s;
      }
      for (final k in const [
        'title',
        'full_name',
        'customer_name',
        'supplier_name',
        'label',
      ]) {
        if (label != null && label.isNotEmpty) break;
        final v = row[k];
        if (v != null) {
          final s = v.toString().trim();
          if (s.isNotEmpty) label = s;
        }
      }
      label ??= name;
      // Offline-only rows (no server_name yet) carry their mobile_uuid as
      // the picker value; the form must mark `<field>__is_local: 1` so the
      // push pipeline rewrites the UUID after the target's INSERT lands.
      final isLocal = (row['server_name'] as String?) == null;
      out.add(
        LinkOptionEntity(
          doctype: doctype,
          name: name,
          label: label,
          dataJson: jsonEncode(row),
          lastUpdated: now,
          isLocal: isLocal,
        ),
      );
    }
    return out;
  }

  /// Normalize filter doctype to match the queried doctype.
  /// Fixes 417 "Field not permitted" when meta uses singular form (e.g. Village)
  /// but API queries plural (Villages).
  ///
  /// Accepts both Frappe filter forms:
  ///   3-tuple [field, op, value]  — doctype is prepended from [doctype].
  ///   4-tuple [dt, field, op, value] — dt is replaced with [doctype] if it
  ///   differs (singular/plural mismatch) or is null/empty.
  static List<List<dynamic>>? _normalizeFiltersForDoctype(
    String doctype,
    List<List<dynamic>>? filters,
  ) {
    if (filters == null || filters.isEmpty) return filters;
    final result = <List<dynamic>>[];
    for (final filter in filters) {
      if (filter.length == 3) {
        result.add([doctype, filter[0], filter[1], filter[2]]);
        continue;
      }
      if (filter.length < 4) {
        debugPrint(
          'LinkOptionService: malformed filter (length ${filter.length}), skipping',
        );
        continue;
      }
      final filterDoctype = filter[0]?.toString();
      if (filterDoctype == null ||
          filterDoctype.isEmpty ||
          filterDoctype != doctype) {
        result.add([doctype, filter[1], filter[2], filter[3]]);
      } else {
        result.add(List<dynamic>.from(filter));
      }
    }
    return result.isEmpty ? null : result;
  }

  @visibleForTesting
  static List<List<dynamic>>? normalizeFiltersForDoctypeForTesting(
    String doctype,
    List<List<dynamic>>? filters,
  ) => _normalizeFiltersForDoctype(doctype, filters);

  /// Returns field names that are dependencies in link_filters (eval:doc.xxx).
  /// Handles both `eval:doc.state` and `eval: doc.state` (Frappe standard format).
  /// e.g. [["District","state","=","eval: doc.state"]] -> ["state"]
  static List<String> getDependentFieldNames(String? linkFiltersJson) {
    if (linkFiltersJson == null || linkFiltersJson.isEmpty) return [];
    try {
      final decoded = jsonDecode(linkFiltersJson) as dynamic;
      final filters = decoded is List
          ? List<dynamic>.from(decoded)
          : <dynamic>[];
      final names = <String>[];
      for (final filter in filters) {
        if (filter is! List) continue;
        for (final elem in filter) {
          if (elem is! String) continue;
          final extracted = DependsOnEvaluator.extractEvalDocField(elem);
          final fieldName =
              extracted ??
              (elem.startsWith('eval:doc.') ? elem.substring(9).trim() : null);
          if (fieldName != null && fieldName.isNotEmpty) {
            if (!names.contains(fieldName)) names.add(fieldName);
          }
        }
      }
      return names;
    } catch (e, st) {
      debugPrint(
        'LinkOptionService.dependentFieldNames parse failed — $e\n$st',
      );
      return [];
    }
  }

  /// Parse Frappe link_filters and build API filters.
  /// Frappe format: [["District","state","=","eval: doc.state"]]
  /// Handles both `eval:doc.x` and `eval: doc.x` (Frappe standard format).
  /// API get_list accepts: [["DocType", "field", "operator", value]] (4 elements).
  static List<List<dynamic>>? parseLinkFilters(
    String? linkFiltersJson,
    Map<String, dynamic> formData,
  ) {
    if (linkFiltersJson == null || linkFiltersJson.isEmpty) return null;
    try {
      final decoded = jsonDecode(linkFiltersJson) as dynamic;
      final filters = decoded is List
          ? List<dynamic>.from(decoded)
          : <dynamic>[];
      final result = <List<dynamic>>[];
      for (final filter in filters) {
        if (filter is! List || filter.length < 4) continue;
        dynamic value = filter[3];
        if (value is String) {
          final fieldName = DependsOnEvaluator.extractEvalDocField(value);
          if (fieldName != null) {
            value = formData[fieldName];
            if (value == null || value == '') continue;
          }
        }
        result.add([filter[0], filter[1], filter[2], value]);
      }
      return result.isEmpty ? null : result;
    } catch (e, st) {
      debugPrint('LinkOptionService.parseLinkFilters parse failed — $e\n$st');
      return null;
    }
  }

  /// Resolves filters for a link-option fetch.
  ///
  /// Precedence:
  /// 1. If [hook] is provided and `field.fieldname` is non-null, invoke it.
  ///    - Non-null result → use `result.filters` (empty list normalizes to null).
  ///    - Null result → fall through to meta.
  ///    - **Throws are caught and treated as null** — host hook failures must
  ///      never propagate into the SDK's UI layer (would freeze the dropdown
  ///      in its loading state). Logged via [debugPrint] for diagnostics.
  /// 2. Parse meta `linkFilters` via [parseLinkFilters] against a merged
  ///    `parentFormData ∪ rowData` view (rowData wins on key collision).
  ///    Mirrors Frappe Desk: child-row Link filters can reference parent
  ///    fields via `eval: doc.X`, just like client scripts that read
  ///    `frm.doc` from a child-row context. For top-level forms
  ///    `parentFormData` equals `rowData`, so the merge is a no-op.
  static List<List<dynamic>>? resolveFilters({
    required DocField field,
    required Map<String, dynamic> rowData,
    required Map<String, dynamic> parentFormData,
    LinkFilterBuilder? hook,
  }) {
    final fieldName = field.fieldname;
    if (hook != null && fieldName != null) {
      LinkFilterResult? result;
      try {
        result = hook(field, fieldName, rowData, parentFormData);
      } catch (e, st) {
        debugPrint(
          'LinkOptionService.resolveFilters: LinkFilterBuilder threw for '
          '${field.options}/$fieldName — falling back to meta. $e\n$st',
        );
        result = null;
      }
      if (result != null) {
        final filters = result.filters;
        if (filters == null || filters.isEmpty) return null;
        return filters;
      }
    }
    return parseLinkFilters(field.linkFilters, {...parentFormData, ...rowData});
  }

  /// Safely invokes a host-provided [getLinkFilterBuilder] factory.
  ///
  /// Host apps register builders via a factory keyed on
  /// `(targetDoctype, fieldname)`. That factory itself runs host code (map
  /// lookups, switch dispatch, etc.) and can throw — a thrown factory must
  /// not propagate into the SDK's UI layer the same way a thrown builder
  /// must not (see [resolveFilters]). All five SDK call sites should route
  /// through this helper instead of calling `getLinkFilterBuilder?.call(...)`
  /// directly so the safety guarantee lives in one place.
  ///
  /// Returns `null` when the factory is null, returns null, or throws.
  static LinkFilterBuilder? safeHook(
    LinkFilterBuilder? Function(String doctype, String fieldname)?
    getLinkFilterBuilder,
    String doctype,
    String fieldname,
  ) {
    if (getLinkFilterBuilder == null) return null;
    try {
      return getLinkFilterBuilder(doctype, fieldname);
    } catch (e, st) {
      debugPrint(
        'LinkOptionService.safeHook: getLinkFilterBuilder threw for '
        '$doctype/$fieldname — falling back to meta. $e\n$st',
      );
      return null;
    }
  }

  /// Offline-first link options with optional text search.
  ///
  /// Delegates to the stored [UnifiedResolver]. The [filters] accept Frappe
  /// 4-tuple `[doctype, field, op, value]` or 3-tuple `[field, op, value]`
  /// form. [query] becomes a `LIKE %...%` search on the doctype's title field.
  Future<List<LinkOptionEntity>> getLinkOptionsOffline({
    required String doctype,
    List<List<dynamic>>? filters,
    String? query,
    int page = 0,
    int pageSize = 5000,
  }) async {
    final resolver = _resolver;
    final metaResolver = _metaResolver;
    if (resolver == null || metaResolver == null) return const [];

    final meta = await metaResolver(doctype);
    final titleField = meta.titleField;

    final threeTuples = _toThreeTuples(filters);
    if (query != null && query.isNotEmpty && titleField != null) {
      threeTuples.add([titleField, 'like', '%$query%']);
    }

    final result = await resolver.resolve(
      doctype: doctype,
      filters: threeTuples,
      page: page,
      pageSize: pageSize,
    );

    return _rowsToEntities(result.rows, doctype, titleField);
  }
}
