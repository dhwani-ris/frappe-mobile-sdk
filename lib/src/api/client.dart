// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'package:http/http.dart' as http;
import 'rest_helper.dart';
import 'auth.dart';
import 'doctype_service.dart';
import 'document_service.dart';
import 'attachment_service.dart';
import 'query_builder.dart';

class FrappeClient {
  final RestHelper _restHelper;

  late final AuthService auth;
  late final DoctypeService doctype;
  late final DocumentService document;
  late final AttachmentService attachment;

  FrappeClient(
    String baseUrl, {
    http.Client? httpClient,
    SessionStorage? sessionStorage,
  }) : _restHelper = RestHelper(baseUrl, client: httpClient) {
    auth = AuthService(_restHelper, sessionStorage: sessionStorage);
    doctype = DoctypeService(_restHelper);
    document = DocumentService(_restHelper);
    attachment = AttachmentService(_restHelper);
  }

  Future<void> initialize() async {
    await auth.initialize();
  }

  RestHelper get rest => _restHelper;
  String get baseUrl => _restHelper.baseUrl;

  QueryBuilder doc(String doctype) {
    return QueryBuilder(this.doctype, doctype);
  }

  Future<dynamic> call(
    String method, {
    Map<String, dynamic>? args,
    String httpMethod = 'POST',
  }) {
    return _restHelper.call(method, args: args, httpMethod: httpMethod);
  }
}
