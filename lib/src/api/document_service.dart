// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:convert';
import 'rest_helper.dart';
import 'utils.dart';

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
      return unwrapMessage<Map<String, dynamic>>(response);
    } else {
      final response = await _restHelper.post(
        '/api/resource/$doctype',
        body: data,
      );
      return unwrapData<Map<String, dynamic>>(response);
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
    return unwrapData<Map<String, dynamic>>(response);
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
