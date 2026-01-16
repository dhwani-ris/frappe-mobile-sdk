// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';
import 'rest_helper.dart';

class DocumentService {
  final RestHelper _restHelper;

  DocumentService(this._restHelper);

  Future<Map<String, dynamic>> createDocument(
    String doctype,
    Map<String, dynamic> data, {
    bool useFrappeClient = false,
  }) async {
    if (useFrappeClient) {
      final response = await _restHelper.post(
        '/api/method/frappe.client.insert',
        body: {'doc': jsonEncode(data..['doctype'] = doctype)},
      );
      if (response is Map<String, dynamic> && response.containsKey('message')) {
        return response['message'] as Map<String, dynamic>;
      }
      return response as Map<String, dynamic>;
    } else {
      final response = await _restHelper.post(
        '/api/resource/$doctype',
        body: data,
      );
      if (response is Map<String, dynamic> && response.containsKey('data')) {
        return response['data'] as Map<String, dynamic>;
      }
      return response as Map<String, dynamic>;
    }
  }

  Future<Map<String, dynamic>> updateDocument(
    String doctype,
    String name,
    Map<String, dynamic> data,
  ) async {
    final response = await _restHelper.put(
      '/api/resource/$doctype/$name',
      body: data,
    );
    if (response is Map<String, dynamic> && response.containsKey('data')) {
      return response['data'] as Map<String, dynamic>;
    }
    return response as Map<String, dynamic>;
  }

  Future<void> deleteDocument(String doctype, String name) async {
    await _restHelper.delete('/api/resource/$doctype/$name');
  }

  Future<Map<String, dynamic>> submitDocument(
    String doctype,
    String name,
  ) async {
    return updateDocument(doctype, name, {'docstatus': 1});
  }

  Future<Map<String, dynamic>> cancelDocument(
    String doctype,
    String name,
  ) async {
    return updateDocument(doctype, name, {'docstatus': 2});
  }
}
