// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'exceptions.dart';
import 'rest_helper.dart';
import 'utils.dart';

/// How many names [DoctypeService.listFullDocs] sends per bulk-fetch call.
///
/// Kept equal to the pull engine's page size and to `MAX_BATCH` in
/// `mobile_control/api/bulk_fetch.py`, so one page of a child-bearing
/// doctype costs one bulk call. The server read is set-based — one query
/// for the parents plus one per child table — so the batch size no longer
/// drives server work, only response size.
const int defaultBulkFetchBatchSize = 1000;

class DoctypeService {
  final RestHelper _restHelper;

  /// Names per bulk-fetch call. Starts at [defaultBulkFetchBatchSize] and
  /// is lowered — once — if the backend reports a smaller cap.
  int _bulkFetchBatchSize = defaultBulkFetchBatchSize;

  DoctypeService(this._restHelper);

  Future<Map<String, dynamic>> getDocTypeMeta(String doctype) async {
    final response = await _restHelper.get(
      '/api/method/frappe.desk.form.load.getdoctype',
      queryParams: {'doctype': doctype},
    );

    if (response is Map<String, dynamic> && response.containsKey('docs')) {
      return response;
    }

    return response as Map<String, dynamic>;
  }

  /// Fetches just the `modified` timestamp of a DocType meta. Used by the
  /// offline-first watermark check (spec §4.9). Avoids the full meta payload.
  /// Returns null if the request fails or the DocType has no recorded
  /// modified timestamp on the server.
  Future<String?> getDocTypeWatermark(String doctype) async {
    try {
      final response = await _restHelper.get(
        '/api/method/frappe.client.get_value',
        queryParams: {
          'doctype': 'DocType',
          'filters': jsonEncode({'name': doctype}),
          'fieldname': jsonEncode(['modified']),
        },
      );
      if (response is Map<String, dynamic>) {
        final message = response['message'];
        if (message is Map && message['modified'] != null) {
          return message['modified'].toString();
        }
      }
      return null;
    } catch (e, st) {
      debugPrint(
        'DoctypeService.getDocTypeWatermark($doctype) failed — $e\n$st',
      );
      return null;
    }
  }

  Future<List<dynamic>> list(
    String doctype, {
    List<String>? fields,
    List<List<dynamic>>? filters,
    List<List<dynamic>>? orFilters,
    int limitStart = 0,
    int limitPageLength = 20,
    String? orderBy,
  }) async {
    final methodParams = <String, dynamic>{
      'doctype': doctype,
      'limit_start': limitStart,
      'limit_page_length': limitPageLength,
    };

    if (fields != null) methodParams['fields'] = jsonEncode(fields);
    if (filters != null) methodParams['filters'] = jsonEncode(filters);
    if (orFilters != null && orFilters.isNotEmpty) {
      methodParams['or_filters'] = jsonEncode(orFilters);
    }
    if (orderBy != null) methodParams['order_by'] = orderBy;

    final response = await _restHelper.get(
      '/api/method/frappe.client.get_list',
      queryParams: methodParams,
    );

    if (response is Map<String, dynamic> && response.containsKey('message')) {
      final msg = response['message'];
      if (msg is List) return msg;
      // Frappe returned a non-List message (null, error string, etc.).
      // Treat as empty page — callers see no records and pull continues.
      debugPrint(
        'DoctypeService.list: unexpected message shape for $doctype '
        '(${msg?.runtimeType ?? "null"}) — treating as empty page',
      );
      return [];
    }
    return [];
  }

  /// Counts records via `frappe.client.get_count`. Whitelisted in
  /// `apps/frappe/frappe/client.py:79`. Returns the total matching count,
  /// or 0 when the response is malformed. Optional [filters] follow the
  /// same `[field, operator, value]` shape as [list].
  Future<int> count(String doctype, {List<List<dynamic>>? filters}) async {
    final methodParams = <String, dynamic>{'doctype': doctype};
    if (filters != null && filters.isNotEmpty) {
      methodParams['filters'] = jsonEncode(filters);
    }
    final response = await _restHelper.get(
      '/api/method/frappe.client.get_count',
      queryParams: methodParams,
    );
    if (response is Map<String, dynamic>) {
      final message = response['message'];
      if (message is int) return message;
      if (message is num) return message.toInt();
      if (message is String) return int.tryParse(message) ?? 0;
    }
    return 0;
  }

  /// Lists child doctype records with ALL fields.
  /// get_list and reportview only return standard fields for child doctypes.
  /// This fetches names first, then batch-loads full docs via /api/resource.
  Future<List<Map<String, dynamic>>> listChildDocs(
    String doctype, {
    List<List<dynamic>>? filters,
    int limitPageLength = 1000,
  }) async {
    // Step 1: get names (get_list works for this)
    final nameList = await list(
      doctype,
      fields: ['name'],
      filters: filters,
      limitPageLength: limitPageLength,
    );
    if (nameList.isEmpty) return [];

    // Step 2: batch-fetch full documents via /api/resource/{doctype}/{name}
    final docs = <Map<String, dynamic>>[];
    const batchSize = 50;
    for (var i = 0; i < nameList.length; i += batchSize) {
      final batch = nameList.skip(i).take(batchSize);
      final futures = batch.map((n) {
        final name = n is Map<String, dynamic>
            ? n['name']?.toString() ?? ''
            : '';
        if (name.isEmpty) return Future.value(<String, dynamic>{});
        return getByName(doctype, name);
      });
      final results = await Future.wait(futures);
      docs.addAll(results.where((d) => d.isNotEmpty));
    }
    return docs;
  }

  Future<Map<String, dynamic>> getByName(String doctype, String name) async {
    final response = await _restHelper.get('/api/resource/$doctype/$name');
    return unwrapData<Map<String, dynamic>>(response);
  }

  /// Bulk-fetch full parent docs (with embedded child rows) via the
  /// `mobile_sync.get_docs_with_children` server endpoint shipped in
  /// `mobile_control`. The server enforces the same per-doc permission
  /// gate as `/api/resource/<doctype>/<name>` (via
  /// `doc.check_permission("read")`), so denied / missing names are
  /// silently dropped — return length may be < input length.
  ///
  /// Batch size is chosen by [listFullDocs], which starts at
  /// [defaultBulkFetchBatchSize] and backs off if the server reports a
  /// smaller `MAX_BATCH`. Do not hard-code a cap here.
  Future<List<Map<String, dynamic>>> bulkGetWithChildren(
    String doctype,
    List<String> names,
  ) async {
    if (names.isEmpty) return [];
    final response = await _restHelper.post(
      '/api/method/mobile_sync.get_docs_with_children',
      body: {'doctype': doctype, 'names': names},
    );
    final dynamic message = response is Map<String, dynamic>
        ? response['message']
        : response;
    if (message is! List) return [];
    return [
      for (final row in message)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }

  /// Pages through `frappe.client.get_list` for names, then bulk-fetches
  /// full documents (parents + child rows) via the server-side
  /// `mobile_sync.get_docs_with_children` endpoint. Used by the pull
  /// engine for parents that declare child tables, since `get_list`
  /// returns flat parent rows only — child arrays are missing.
  ///
  /// Caller is responsible for paginating across the full result set; one
  /// call returns at most [limitPageLength] full docs starting at
  /// [limitStart].
  Future<List<Map<String, dynamic>>> listFullDocs(
    String doctype, {
    List<List<dynamic>>? filters,
    int limitStart = 0,
    int limitPageLength = 1000,
    String? orderBy,
  }) async {
    final nameList = await list(
      doctype,
      fields: ['name'],
      filters: filters,
      limitStart: limitStart,
      limitPageLength: limitPageLength,
      orderBy: orderBy,
    );
    if (nameList.isEmpty) return [];

    // Use `?.toString()` (matches listChildDocs) so int-valued `name`
    // fields from Frappe's autoname-by-numeric-series — which historically
    // dropped silently under the `is String` check — round-trip correctly.
    final names = <String>[
      for (final n in nameList)
        if (n is Map<String, dynamic>)
          if (n['name']?.toString() case final String s when s.isNotEmpty) s,
    ];
    if (names.isEmpty) return [];

    // Match the server's MAX_BATCH cap (`mobile_control.api.bulk_fetch`),
    // which equals the pull engine's page size — so one page is one call.
    // It was 200, which cost five calls per page on top of the names
    // query; each of those was ~1.1s against prod, and the three heavy
    // Swasti doctypes all take this path.
    final docs = <Map<String, dynamic>>[];
    var i = 0;
    while (i < names.length) {
      final chunkSize = _bulkFetchBatchSize;
      final chunk = names.sublist(i, math.min(i + chunkSize, names.length));
      List<Map<String, dynamic>> batch;
      try {
        batch = await bulkGetWithChildren(doctype, chunk);
      } on ValidationException catch (e) {
        // A backend still on the old cap rejects the batch by size. The
        // app can outrun its server — a device updates from the store the
        // moment the build is live, whether or not Frappe has been
        // deployed — so back off to the cap it reports and re-send the
        // same slice rather than stranding the doctype. The cap is kept on
        // the service, so a full pull pays this discovery once and not
        // once per page.
        final cap = _batchCapFromError(e);
        if (cap != null && cap > 0 && cap < chunkSize) {
          // Logged once per session, at the moment the cap is learned. A
          // silent back-off means a field device that is quietly paying five
          // round-trips per page looks identical to one that is not — and
          // "it worked but slowly" is exactly the failure we could not
          // diagnose from logs before.
          debugPrint(
            'DoctypeService: server caps bulk fetch at $cap '
            '(asked for $chunkSize) — backing off for this session. '
            'Deploy mobile_control >= the set-based bulk_fetch to remove it.',
          );
          _bulkFetchBatchSize = cap;
          continue;
        }
        rethrow;
      } on ApiException catch (e) {
        // Older deployments may not have `mobile_control` (or have a
        // version without `mobile_sync.get_docs_with_children`). Fall
        // back to per-name GETs only on 404 — let 5xx / auth / other
        // failures propagate so they aren't masked as silent N+1.
        if (e.statusCode != 404) rethrow;
        batch = await _perNameFallback(doctype, chunk);
      }
      docs.addAll(batch);
      i += chunk.length;
    }
    return docs;
  }

  /// The batch cap a server advertises when it refuses an over-sized
  /// request, or null when the failure was something else.
  ///
  /// Matched against the raw error body rather than
  /// [FrappeException.message]: the message has been through
  /// `toUserFriendlyMessage`, which rewrites text it recognises.
  static int? _batchCapFromError(ValidationException e) {
    final haystack = '${e.message} ${e.errors ?? ''}';
    final match = RegExp(
      r'exceeds limit of\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(haystack);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  Future<List<Map<String, dynamic>>> _perNameFallback(
    String doctype,
    List<String> names,
  ) async {
    // Bounded concurrency: a 200-name chunk fanned out as 200 simultaneous
    // sockets can trip per-host limits and trigger a thundering-herd retry
    // storm against an already-strained server.
    const int sliceSize = 20;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < names.length; i += sliceSize) {
      final slice = names.sublist(i, math.min(i + sliceSize, names.length));
      final results = await Future.wait(
        slice.map((n) => getByName(doctype, n)),
      );
      out.addAll(results.where((d) => d.isNotEmpty));
    }
    return out;
  }
}
