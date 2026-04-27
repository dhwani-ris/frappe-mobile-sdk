import 'dart:convert';

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

  /// Primary constructor — inject a wired [UnifiedResolver].
  LinkOptionService(UnifiedResolver resolver, MetaResolverFn metaResolver)
      : _resolver = resolver,
        _metaResolver = metaResolver;

  /// Test / subclass constructor. Use when all methods are overridden and no
  /// resolver is needed (e.g. recording mocks in widget tests).
  LinkOptionService.withoutResolver()
      : _resolver = null,
        _metaResolver = null;

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
    final threeTuples = <List<dynamic>>[];
    if (normalizedFilters != null) {
      for (final f in normalizedFilters) {
        if (f.length == 4) {
          threeTuples.add([f[1], f[2], f[3]]);
        } else if (f.length == 3) {
          threeTuples.add(List<dynamic>.from(f));
        }
      }
    }

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
      final name =
          (row['server_name'] as String?) ??
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
      out.add(
        LinkOptionEntity(
          doctype: doctype,
          name: name,
          label: label,
          dataJson: jsonEncode(row),
          lastUpdated: now,
        ),
      );
    }
    return out;
  }

  /// Normalize filter doctype to match the queried doctype.
  /// Fixes 417 "Field not permitted" when meta uses singular form (e.g. Village)
  /// but API queries plural (Villages).
  static List<List<dynamic>>? _normalizeFiltersForDoctype(
    String doctype,
    List<List<dynamic>>? filters,
  ) {
    if (filters == null || filters.isEmpty) return filters;
    final result = <List<dynamic>>[];
    for (final filter in filters) {
      if (filter.length < 4) continue;
      final filterDoctype = filter[0]?.toString();
      if (filterDoctype == null || filterDoctype.isEmpty) {
        result.add(List<dynamic>.from(filter));
        continue;
      }
      if (filterDoctype != doctype) {
        result.add([doctype, filter[1], filter[2], filter[3]]);
      } else {
        result.add(List<dynamic>.from(filter));
      }
    }
    return result.isEmpty ? null : result;
  }

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
    } catch (_) {
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
    } catch (_) {
      return null;
    }
  }

  /// Resolves filters for a link-option fetch.
  ///
  /// Precedence:
  /// 1. If [hook] is provided and `field.fieldname` is non-null, invoke it.
  ///    - Non-null result → use `result.filters` (empty list normalizes to null).
  ///    - Null result → fall through to meta.
  /// 2. Parse meta `linkFilters` via [parseLinkFilters] against [rowData].
  static List<List<dynamic>>? resolveFilters({
    required DocField field,
    required Map<String, dynamic> rowData,
    required Map<String, dynamic> parentFormData,
    LinkFilterBuilder? hook,
  }) {
    final fieldName = field.fieldname;
    if (hook != null && fieldName != null) {
      final result = hook(field, fieldName, rowData, parentFormData);
      if (result != null) {
        final filters = result.filters;
        if (filters == null || filters.isEmpty) return null;
        return filters;
      }
    }
    return parseLinkFilters(field.linkFilters, rowData);
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

    final threeTuples = <List>[];
    if (filters != null) {
      for (final f in filters) {
        if (f.length == 4) {
          threeTuples.add([f[1], f[2], f[3]]);
        } else if (f.length == 3) {
          threeTuples.add(List<dynamic>.from(f));
        }
      }
    }
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
