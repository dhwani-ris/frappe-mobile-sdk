// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';
import 'dart:math' as math;
import 'exceptions.dart';
import 'rest_helper.dart';

class DoctypeService {
  final RestHelper _restHelper;

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
    } catch (_) {
      return null;
    }
  }

  Future<List<dynamic>> list(
    String doctype, {
    List<String>? fields,
    List<List<dynamic>>? filters,
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
    if (orderBy != null) methodParams['order_by'] = orderBy;

    final response = await _restHelper.get(
      '/api/method/frappe.client.get_list',
      queryParams: methodParams,
    );

    if (response is Map<String, dynamic> && response.containsKey('message')) {
      return response['message'] as List<dynamic>;
    }
    return [];
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
    if (response is Map<String, dynamic> && response.containsKey('data')) {
      return response['data'] as Map<String, dynamic>;
    }
    return response as Map<String, dynamic>;
  }

  /// Bulk-fetch full parent docs (with embedded child rows) via the
  /// `mobile_sync.get_docs_with_children` server endpoint shipped in
  /// `mobile_control`. The server enforces the same per-doc permission
  /// gate as `/api/resource/<doctype>/<name>` (via
  /// `doc.check_permission("read")`), so denied / missing names are
  /// silently dropped — return length may be < input length.
  ///
  /// Must be kept in sync with `MAX_BATCH` on the server (200).
  Future<List<Map<String, dynamic>>> bulkGetWithChildren(
    String doctype,
    List<String> names,
  ) async {
    if (names.isEmpty) return [];
    final response = await _restHelper.post(
      '/api/method/mobile_sync.get_docs_with_children',
      body: {'doctype': doctype, 'names': names},
    );
    final dynamic message =
        response is Map<String, dynamic> ? response['message'] : response;
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

    final names = <String>[
      for (final n in nameList)
        if (n is Map<String, dynamic> && n['name'] is String)
          (n['name'] as String),
    ];
    if (names.isEmpty) return [];

    // Match the server's MAX_BATCH cap. Each chunk is a single HTTP
    // round-trip, so this typically reduces a 1000-row pull from
    // ~1001 calls (1 list + 1000 per-name GETs) down to ~6 calls.
    const int chunkSize = 200;
    final docs = <Map<String, dynamic>>[];
    for (var i = 0; i < names.length; i += chunkSize) {
      final chunk = names.sublist(i, math.min(i + chunkSize, names.length));
      List<Map<String, dynamic>> batch;
      try {
        batch = await bulkGetWithChildren(doctype, chunk);
      } on ApiException catch (e) {
        // Older deployments may not have `mobile_control` (or have a
        // version without `mobile_sync.get_docs_with_children`). Fall
        // back to per-name GETs only on 404 — let 5xx / auth / other
        // failures propagate so they aren't masked as silent N+1.
        if (e.statusCode != 404) rethrow;
        batch = await _perNameFallback(doctype, chunk);
      }
      docs.addAll(batch);
    }
    return docs;
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
