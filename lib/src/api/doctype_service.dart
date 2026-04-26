// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';
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

  /// Pages through `frappe.client.get_list` for names, then batch-fetches
  /// each full document via `/api/resource/{doctype}/{name}`. Used by the
  /// pull engine for parents that declare child tables, since
  /// `get_list` returns flat parent rows only — child arrays are missing.
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
}
