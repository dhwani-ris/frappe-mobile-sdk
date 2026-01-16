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

  Future<List<dynamic>> list(
    String doctype, {
    List<String>? fields,
    List<List<dynamic>>? filters,
    int limit_start = 0,
    int limit_page_length = 20,
    String? order_by,
  }) async {
    final methodParams = <String, dynamic>{
      'doctype': doctype,
      'limit_start': limit_start,
      'limit_page_length': limit_page_length,
    };

    if (fields != null) methodParams['fields'] = jsonEncode(fields);
    if (filters != null) methodParams['filters'] = jsonEncode(filters);
    if (order_by != null) methodParams['order_by'] = order_by;

    final response = await _restHelper.get(
      '/api/method/frappe.client.get_list',
      queryParams: methodParams,
    );

    if (response is Map<String, dynamic> && response.containsKey('message')) {
      return response['message'] as List<dynamic>;
    }
    return [];
  }

  Future<Map<String, dynamic>> getByName(String doctype, String name) async {
    final response = await _restHelper.get('/api/resource/$doctype/$name');
    if (response is Map<String, dynamic> && response.containsKey('data')) {
      return response['data'] as Map<String, dynamic>;
    }
    return response as Map<String, dynamic>;
  }
}
