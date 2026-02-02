// Copyright (c) 2026, Bhushan Barbuddhe and contributors
// For license information, please see license.txt

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart';
import 'exceptions.dart';
import 'utils.dart';
import '../utils/api_tracer.dart';

class RestHelper {
  final String baseUrl;
  final http.Client _client;

  /// Called on 401 when using bearer token. Return true if token was refreshed.
  final Future<bool> Function()? onTokenExpired;

  String? _sidCookie;
  String? _apiKey;
  String? _apiSecret;
  String? _bearerToken;

  http.Client get client => _client;

  RestHelper(String baseUrlParam, {http.Client? client, this.onTokenExpired})
    : baseUrl = baseUrlParam.endsWith('/')
          ? baseUrlParam.substring(0, baseUrlParam.length - 1)
          : baseUrlParam,
      _client = client ?? http.Client();

  void setSessionCookie(String sid) {
    _sidCookie = sid;
  }

  void setApiKey(String key, String secret) {
    _apiKey = key;
    _apiSecret = secret;
  }

  void setBearerToken(String? token) {
    _bearerToken = token;
  }

  void clearSession() {
    _sidCookie = null;
    _apiKey = null;
    _apiSecret = null;
    _bearerToken = null;
  }

  Map<String, String> _getHeaders() {
    final headers = <String, String>{'Accept': 'application/json'};

    if (_bearerToken != null) {
      headers['Authorization'] = 'Bearer $_bearerToken';
    } else if (_sidCookie != null) {
      headers['Cookie'] =
          'sid=$_sidCookie; system_user=yes; full_name=Guest; user_id=Guest; user_image=';
    } else if (_apiKey != null && _apiSecret != null) {
      headers['Authorization'] = 'token $_apiKey:$_apiSecret';
    }

    return headers;
  }

  Future<dynamic> get(
    String endpoint, {
    Map<String, dynamic>? queryParams,
  }) async {
    return _request('GET', endpoint, queryParams: queryParams);
  }

  Future<dynamic> post(String endpoint, {dynamic body}) async {
    return _request('POST', endpoint, body: body);
  }

  Future<dynamic> put(String endpoint, {dynamic body}) async {
    return _request('PUT', endpoint, body: body);
  }

  Future<dynamic> delete(String endpoint) async {
    return _request('DELETE', endpoint);
  }

  Future<dynamic> _request(
    String method,
    String endpoint, {
    Map<String, dynamic>? queryParams,
    dynamic body,
  }) async {
    var uri = Uri.parse('$baseUrl$endpoint');
    if (queryParams != null) {
      uri = uri.replace(
        queryParameters: queryParams.map((k, v) => MapEntry(k, v.toString())),
      );
    }

    final headers = _getHeaders();
    if (method != 'GET' && body != null) {
      headers['Content-Type'] = 'application/json';
    }

    ApiTracer.traceRequest(
      method: method,
      url: uri.toString(),
      queryParams: method == 'GET' ? queryParams : null,
      body: method != 'GET' ? body : null,
    );

    int attempts = 0;
    while (attempts < 3) {
      try {
        http.Response response;
        switch (method) {
          case 'GET':
            response = await _client.get(uri, headers: headers);
            break;
          case 'POST':
            response = await _client.post(
              uri,
              headers: headers,
              body: body != null ? jsonEncode(body) : null,
            );
            break;
          case 'PUT':
            response = await _client.put(
              uri,
              headers: headers,
              body: body != null ? jsonEncode(body) : null,
            );
            break;
          case 'DELETE':
            response = await _client.delete(uri, headers: headers);
            break;
          default:
            throw ApiException('Unsupported HTTP method: $method');
        }

        ApiTracer.traceResponse(
          statusCode: response.statusCode,
          url: uri.toString(),
          body: response.statusCode >= 400 ? response.body : null,
          error: null,
        );

        return _handleResponse(response);
      } on AuthException catch (e) {
        if (e.statusCode == 401 &&
            _bearerToken != null &&
            onTokenExpired != null) {
          final refreshed = await onTokenExpired!();
          if (refreshed) {
            attempts++;
            continue;
          }
        }
        rethrow;
      } on SocketException {
        if (method == 'GET' && attempts < 2) {
          attempts++;
          await Future.delayed(Duration(milliseconds: 500 * (1 << attempts)));
          continue;
        }
        throw NetworkException('No internet connection');
      } catch (e) {
        if (e is FrappeException) rethrow;
        throw NetworkException('Request failed: $e');
      }
    }
  }

  dynamic _handleResponse(http.Response response) {
    dynamic body;
    try {
      body = jsonDecode(response.body);
    } catch (e) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response.body;
      }
      throw ApiException(
        toUserFriendlyMessage(response.body),
        response.statusCode,
        response.body,
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw AuthException(
        toUserFriendlyMessage(extractErrorMessage(body)),
        response.statusCode,
      );
    }

    if (response.statusCode == 417) {
      throw ValidationException(
        toUserFriendlyMessage(extractErrorMessage(body)),
        body is Map<String, dynamic> ? body : null,
      );
    }

    if (response.statusCode == 404) {
      throw ApiException(toUserFriendlyMessage(extractErrorMessage(body)), 404);
    }

    throw ApiException(
      toUserFriendlyMessage(extractErrorMessage(body)),
      response.statusCode,
      body,
    );
  }

  Future<dynamic> call(
    String method, {
    Map<String, dynamic>? args,
    String httpMethod = 'POST',
  }) async {
    final endpoint = '/api/method/$method';
    if (httpMethod.toUpperCase() == 'GET') {
      return get(endpoint, queryParams: args);
    } else {
      return post(endpoint, body: args);
    }
  }

  Future<dynamic> uploadFile(
    String endpoint,
    String fieldName,
    File file, {
    Map<String, String>? fields,
  }) async {
    var uri = Uri.parse('$baseUrl$endpoint');
    var request = http.MultipartRequest('POST', uri);

    request.headers.addAll(_getHeaders());

    if (fields != null) {
      request.fields.addAll(fields);
    }

    var stream = http.ByteStream(file.openRead());
    var length = await file.length();

    var multipartFile = http.MultipartFile(
      fieldName,
      stream,
      length,
      filename: basename(file.path),
    );

    request.files.add(multipartFile);

    try {
      var streamedResponse = await _client.send(request);
      var response = await http.Response.fromStream(streamedResponse);
      return _handleResponse(response);
    } catch (e) {
      if (e is FrappeException) rethrow;
      throw NetworkException('Upload failed: $e');
    }
  }
}
