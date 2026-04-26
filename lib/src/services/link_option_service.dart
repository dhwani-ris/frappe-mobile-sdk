import 'dart:convert';

import '../api/client.dart';
import '../database/app_database.dart';
import '../database/entities/link_option_entity.dart';
import '../models/doc_field.dart';
import '../models/doc_type_meta.dart';
import '../models/link_filter_result.dart';
import '../query/unified_resolver.dart';
import '../utils/depends_on_evaluator.dart';
import 'meta_service.dart';

/// Fetches link field options from API at runtime. Link filters are sent to the API; no DB table.
///
/// No client-side result cache by design — matches Frappe Desk semantics
/// (every dropdown re-queries) and avoids staleness when dependent fields
/// mutate. Per-form dedupe lives in [LinkFieldCoordinator._resultsCache],
/// which bounds cost to one API call per (doctype, filters) per form open.
class LinkOptionService {
  final FrappeClient _client;

  LinkOptionService(this._client);

  /// Fetches link options from API (with optional filters). No DB; filters sent to server.
  Future<List<LinkOptionEntity>> getLinkOptions(
    String doctype, {
    List<List<dynamic>>? filters,
  }) async {
    final normalizedFilters = _normalizeFiltersForDoctype(doctype, filters);
    final meta = await _getDocTypeMeta(doctype);
    final titleField = meta?.titleField;

    List<dynamic> documents;

    try {
      // For child doctypes (istable=1), get_list/reportview only return
      // standard fields. Batch-fetch full docs via /api/resource instead.
      if (meta != null && meta.isTable) {
        documents = await _client.doctype.listChildDocs(
          doctype,
          filters: normalizedFilters,
          limitPageLength: 5000,
        );
      } else {
        documents = await _client.doctype.list(
          doctype,
          fields: ['*'],
          filters: normalizedFilters,
          limitPageLength: 5000,
        );
      }
    } catch (_) {
      return [];
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final linkOptions = <LinkOptionEntity>[];

    for (final doc in documents) {
      final docMap = doc is Map<String, dynamic> ? doc : null;
      if (docMap == null) continue;
      final name = docMap['name'] as String? ?? '';
      if (name.isEmpty) continue;
      String? label;

      // Determine the display label for the link option
      // First try the title field if it exists and has a value
      if (titleField != null &&
          docMap[titleField] != null &&
          docMap[titleField].toString().trim().isNotEmpty) {
        label = docMap[titleField].toString();
      }
      // Fall back to common label fields if title field is not available or empty
      for (final k in [
        'title',
        'full_name',
        'customer_name',
        'supplier_name',
        'label',
      ]) {
        if (label != null && label.isNotEmpty) break;
        if (docMap.containsKey(k) && docMap[k] != null) {
          label = docMap[k].toString();
          break;
        }
      }
      // Default to the document name if no label is found
      label ??= name;
      linkOptions.add(
        LinkOptionEntity(
          doctype: doctype,
          name: name,
          label: label,
          dataJson: jsonEncode(docMap),
          lastUpdated: now,
        ),
      );
    }

    return linkOptions;
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
          // Prefer the evaluator helper (supports "eval: doc.x" and variations)
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

  Future<DocTypeMeta?> _getDocTypeMeta(String doctype) async {
    try {
      final database = await AppDatabase.getInstance();
      final metaService = MetaService(_client, database);
      return await metaService.getMeta(doctype);
    } catch (_) {
      return null;
    }
  }

  /// Offline-first variant of [getLinkOptions]. Routes the read through
  /// a [UnifiedResolver] (Spec §6.1) so the dropdown is sourced from the
  /// local `docs__<doctype>` table, with a background API refresh fired
  /// when online.
  ///
  /// Returns the same `List<LinkOptionEntity>` shape as [getLinkOptions]
  /// — drop-in replacement for callers that have already wired a
  /// resolver. When the local store is empty (e.g. first launch before
  /// initial sync), the result is empty; consumers that need API
  /// fallback in that window should call [getLinkOptions] instead.
  ///
  /// [meta] is read via the resolver's `metaResolver` when omitted —
  /// keeps this entry-point fully offline (no network) so dropdowns
  /// keep responding when the device is air-gapped.
  ///
  /// [filters] accepts the Frappe 4-tuple form `[doctype, col, op, val]`
  /// for parity with [getLinkOptions]; the doctype prefix is stripped
  /// before forwarding to the resolver. [query] becomes a `LIKE %...%`
  /// against the doctype's `title_field` (FilterParser routes through
  /// the `__norm` companion when one exists for case-insensitive,
  /// accent-insensitive search).
  Future<List<LinkOptionEntity>> getLinkOptionsOffline({
    required String doctype,
    required UnifiedResolver resolver,
    DocTypeMeta? meta,
    List<List<dynamic>>? filters,
    String? query,
    int page = 0,
    int pageSize = 5000,
  }) async {
    final resolved = meta ?? await resolver.metaResolver(doctype);
    final titleField = resolved.titleField;

    final threeTuples = <List>[];
    if (filters != null) {
      for (final f in filters) {
        // Strip the doctype prefix from the 4-tuple form.
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

    final now = DateTime.now().millisecondsSinceEpoch;
    final out = <LinkOptionEntity>[];
    for (final row in result.rows) {
      final name = (row['server_name'] as String?) ??
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
}
